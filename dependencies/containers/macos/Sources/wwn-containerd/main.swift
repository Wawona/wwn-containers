//===----------------------------------------------------------------------===//
// wwn-containerd — macOS OCI execution backend for Wawona.
//
// Runs a Linux OCI container inside a per-container lightweight VM using Apple's
// Containerization framework (Virtualization.framework + vminitd, gRPC/vsock).
// This is the macOS "true container execution" path from wwn-containers'
// COMPLIANCE.md: direct/notarized channel only (needs the virtualization
// entitlement; not Mac App Store viable).
//
// The universal, always-compliant image-management surface lives in the Rust
// `wwn-oci` crate. This bridge is *execution only*; it delegates image pull to
// Containerization's own OCI store (which mirrors what wwn-oci does) so the two
// stay interchangeable.
//===----------------------------------------------------------------------===//

import ArgumentParser
import Containerization
import ContainerizationError
import ContainerizationOCI
import ContainerizationOS
import Darwin
import Foundation

@main
struct WWNContainerd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wwn-containerd",
        abstract: "Run Linux OCI containers on macOS via Apple's Containerization framework",
        subcommands: [Run.self],
        defaultSubcommand: Run.self
    )
}

#if os(macOS)
extension WWNContainerd {
    /// Boot a container from an image reference and run a process, streaming the
    /// host tty in/out. Mirrors Apple's `cctl run` macOS path, parameterized for
    /// Wawona (kernel path + vsock port for the Wayland bridge).
    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run",
            abstract: "Run a container"
        )

        @Option(name: [.customLong("image"), .customShort("i")], help: "OCI image reference")
        var imageReference: String = "docker.io/library/alpine:3.20"

        @Option(name: .long, help: "Container id")
        var id: String = "wawona"

        @Option(name: [.customLong("kernel"), .customShort("k")], help: "Linux kernel image path")
        var kernel: String

        // Path to a prebuilt vminitd ext4 initfs (the guest PID 1). When set, the
        // manager mounts it directly instead of resolving the vminit image from
        // the Apple container system's image store — so wwn-containers can
        // ship/build the initfs and boot self-contained (no pre-seeded store).
        @Option(name: .customLong("initfs"), help: "Path to a prebuilt vminitd ext4 initfs (bundled). If unset, resolves the vminit image from the Apple container system's image store.")
        var initfs: String?

        // Root of the Apple container system's application data (image store,
        // kernel registry, plugin state). Mirrors Apple's own `ApplicationRoot`:
        // the CONTAINER_APP_ROOT environment variable wins, then the system
        // default (~/Library/Application Support/com.apple.container).
        @Option(name: .customLong("app-root"), help: "Apple container system app-data root (default: $CONTAINER_APP_ROOT or ~/Library/Application Support/com.apple.container)")
        var appRoot: String?

        @Option(name: [.customLong("cpus"), .customShort("c")], help: "vCPUs")
        var cpus: Int = 2

        @Option(name: [.customLong("memory"), .customShort("m")], help: "Memory (MiB)")
        var memory: UInt64 = 1024

        @Option(name: .customLong("fs-size"), help: "Rootfs block size (MiB)")
        var fsSizeInMB: UInt64 = 2048

        @Flag(name: .customLong("rosetta"), help: "Enable Rosetta x86_64 emulation")
        var rosetta = false

        @Flag(name: .long, help: "Read-only rootfs")
        var readOnly = false

        @Flag(name: .long, help: "Run with an init process (signal fwd + zombie reaping)")
        var `init` = false

        @Option(name: .long, help: "Working directory")
        var cwd: String = "/"

        // Wawona-specific: forward a guest vsock port (where the guest's waypipe
        // server binds) to a host unix socket, so the container's Wayland session
        // can be bridged into Wawona. 0 disables.
        @Option(name: .customLong("wayland-vsock-port"), help: "Guest vsock port to bridge to Wawona (0 = off)")
        var waylandVsockPort: UInt32 = 0

        // Guest-side waypipe binary (a Linux build, e.g. nixpkgs waypipe for
        // aarch64-linux), injected into the container as /usr/local/bin/waypipe
        // when --wayland-vsock-port is set. Resolves via WAWONA_WAYPIPE_GUEST
        // when omitted.
        @Option(name: .customLong("waypipe-guest-bin"), help: "Host path to the guest waypipe binary to inject (default: $WAWONA_WAYPIPE_GUEST)")
        var waypipeGuestBin: String?

        @Argument(parsing: .captureForPassthrough)
        var arguments: [String] = ["/bin/sh"]

        func run() async throws {
            let kernel = Kernel(
                path: URL(fileURLWithPath: kernel),
                platform: .linuxArm
            )

            let network: Network?
            if #available(macOS 26, *) {
                network = try VmnetNetwork()
            } else {
                network = nil
            }

            var manager: ContainerManager
            if let initfsPath = initfs {
                let initMount = Mount.block(
                    format: "ext4",
                    source: initfsPath,
                    destination: "/",
                    options: ["ro"]
                )
                manager = try ContainerManager(
                    kernel: kernel,
                    initfs: initMount,
                    network: network,
                    rosetta: rosetta
                )
            } else {
                // Resolve the vminit initfs from the Apple container system's
                // image store (the same store `container` CLI uses), instead of
                // the framework's private default store. The store registers
                // vminit under its fully-qualified OCI reference, so discover
                // it rather than guessing a short-name or pinning a version.
                let storeRoot = Self.resolveAppRoot(appRoot)
                let vminitReference = try Self.discoverVminitReference(in: storeRoot)
                manager = try await ContainerManager(
                    kernel: kernel,
                    initfsReference: vminitReference,
                    root: storeRoot,
                    network: network,
                    rosetta: rosetta
                )
            }

            let current = try Terminal.current
            try current.setraw()
            defer { current.tryReset() }

            let port = waylandVsockPort
            let container = try await manager.create(
                id,
                reference: imageReference,
                rootfsSizeInBytes: fsSizeInMB.mib(),
                readOnly: readOnly,
                networking: true
            ) { config in
                config.cpus = cpus
                config.memoryInBytes = memory.mib()
                config.process.setTerminalIO(terminal: current)
                config.process.arguments = arguments
                config.process.workingDirectory = cwd
                config.useInit = self.`init`
                // Wawona Wayland bridge (guest side): inject the host's Linux
                // waypipe into the container as a read-only file mount and
                // wrap the command so ANY image runs its app through
                // `waypipe --vsock -s <port> server` — no special image needed.
                // The sh preamble creates XDG_RUNTIME_DIR (the C waypipe binds
                // its display socket there and never mkdir's; stock images
                // lack /run/user/0).
                if port != 0 {
                    let guestWaypipe = try Self.resolveGuestWaypipeBin(waypipeGuestBin)
                    config.mounts.append(.share(
                        source: guestWaypipe,
                        destination: "/usr/local/bin/waypipe",
                        options: ["ro"]
                    ))
                    let wrapper = "mkdir -p \"$XDG_RUNTIME_DIR\" && chmod 0700 \"$XDG_RUNTIME_DIR\" && exec /usr/local/bin/waypipe --no-gpu --vsock -s \"$WAWONA_VSOCK_PORT\" server -- \"$@\""
                    config.process.arguments = ["/bin/sh", "-c", wrapper, "wawona-waypipe"] + arguments
                    config.process.environmentVariables.append("WAYLAND_DISPLAY=wayland-0")
                    config.process.environmentVariables.append("XDG_RUNTIME_DIR=/run/user/0")
                    config.process.environmentVariables.append("WAWONA_VSOCK_PORT=\(port)")
                }
            }

            defer { try? manager.delete(id) }

            try await container.create()
            try await container.start()
            // Signal readiness to the host (WWNContainerRunner polls this
            // file) so Wawona's GUI can stop showing "compiling backend". A
            // file keeps the terminal output clean when the container runs
            // inside a Wawona terminal window.
            Self.writeMarkerFile(environmentKey: "WAWONA_CONTAINER_READY_FILE")
            try? await container.resize(to: try current.size)

            // Wawona Wayland bridge (host side): the guest process is now
            // `waypipe --vsock -s <port> server -- <app>` (injected binary +
            // wrapped command above). Dial the guest's vsock port and attach
            // the host waypipe client directly on the raw fd pair. The
            // framework's unix-socket relay is a byte pipe that strips
            // SCM_RIGHTS (BidirectionalRelay), so the fd handoff
            // (--socket-fds) is the only transport that carries wl_shm fds.
            // The host waypipe must be the waypipe-splitfd build (wwn-waypipe
            // macos.nix parses --socket-fds but cannot use it). Resolve it via
            // WWNP_WAYPIPE_BIN (Wawona's bundled binary) or PATH.
            //
            // The guest waypipe server blocks waiting for a client connection;
            // a relay failure therefore fails the run (the guest session is
            // stuck without it).
            var relay: Foundation.Process?
            if port != 0 {
                relay = try await Self.startWaypipeRelay(container: container, port: port)
            }

            let exit = try await container.wait()
            if let relay, relay.isRunning {
                relay.terminate()
                relay.waitUntilExit()
            }
            Self.writeMarkerFile(environmentKey: "WAWONA_CONTAINER_DONE_FILE")
            try await container.stop()
            if exit.exitCode != 0 {
                throw ExitCode(Int32(exit.exitCode))
            }
        }

        /// Resolve the guest-side waypipe binary (a Linux build injected into
        /// the container as /usr/local/bin/waypipe): --waypipe-guest-bin wins,
        /// then WAWONA_WAYPIPE_GUEST.
        static func resolveGuestWaypipeBin(_ flagValue: String?) throws -> String {
            if let raw = flagValue, !raw.isEmpty {
                let path = (raw as NSString).expandingTildeInPath
                guard FileManager.default.fileExists(atPath: path) else {
                    throw ValidationError("--waypipe-guest-bin: no such file: \(path)")
                }
                return path
            }
            if let env = ProcessInfo.processInfo.environment["WAWONA_WAYPIPE_GUEST"],
               !env.isEmpty
            {
                guard FileManager.default.fileExists(atPath: env) else {
                    throw ValidationError("WAWONA_WAYPIPE_GUEST: no such file: \(env)")
                }
                return env
            }
            throw ValidationError(
                "the Wayland bridge needs a guest waypipe binary: pass --waypipe-guest-bin "
                    + "or set WAWONA_WAYPIPE_GUEST (e.g. nixpkgs waypipe for aarch64-linux)")
        }

        /// Dial the guest vsock port (retrying until the guest waypipe server
        /// binds) and spawn the host waypipe client on the raw fd pair.
        /// WAYLAND_DISPLAY/XDG_RUNTIME_DIR are inherited from the runner, so
        /// the client attaches to Wawona's compositor.
        static func startWaypipeRelay(
            container: LinuxContainer,
            port: UInt32
        ) async throws -> Foundation.Process {
            var handle: FileHandle?
            for attempt in 1...60 {
                do {
                    handle = try await container.dialVsock(port: port)
                    break
                } catch {
                    if attempt == 60 { throw error }
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            guard let handle else {
                throw ValidationError("dialVsock returned nil")
            }

            // Sockets are full-duplex: dup the fd once per direction for the
            // R,W pair waypipe expects.
            let base = handle.fileDescriptor
            let rfd = dup(base)
            let wfd = dup(base)
            guard rfd >= 0, wfd >= 0 else {
                throw ValidationError("dup failed: \(String(cString: strerror(errno)))")
            }

            let waypipePath = ProcessInfo.processInfo.environment["WWNP_WAYPIPE_BIN"] ?? "waypipe"
            let relay = Foundation.Process()
            relay.executableURL = URL(fileURLWithPath: waypipePath)
            relay.arguments = ["--socket-fds", "\(rfd),\(wfd)", "client"]
            do {
                try relay.run()
            } catch {
                throw ValidationError(
                    "failed to spawn \(waypipePath) --socket-fds client: \(error). "
                        + "Provide the waypipe-splitfd build via WWNP_WAYPIPE_BIN.")
            }
            FileHandle.standardError.write(Data(
                "[wwn-containerd] waypipe client on vsock port \(port) (fd \(base), R=\(rfd) W=\(wfd))\n".utf8))
            return relay
        }

        /// Write a small marker file for the host runner, if the environment
        /// requests one. Best effort: a missing or readonly path must not fail
        /// the run.
        static func writeMarkerFile(environmentKey: String) {
            guard let path = ProcessInfo.processInfo.environment[environmentKey],
                  !path.isEmpty
            else { return }
            FileManager.default.createFile(
                atPath: path,
                contents: Data("\(environmentKey)\n".utf8),
                attributes: nil)
        }

        /// The Apple container system's app-data root. Mirrors Apple's own
        /// `ApplicationRoot`: the `--app-root` flag wins, then the
        /// `CONTAINER_APP_ROOT` environment variable, then the system default
        /// (`~/Library/Application Support/com.apple.container`).
        static func resolveAppRoot(_ flagValue: String?) -> URL {
            let raw = flagValue ?? ProcessInfo.processInfo.environment["CONTAINER_APP_ROOT"]
            if let raw, !raw.isEmpty {
                return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            }
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            return support.appendingPathComponent("com.apple.container")
        }

        /// Find the vminit initfs image registered in the container system's
        /// image store. The store keys it under its fully-qualified OCI
        /// reference (`ghcr.io/apple/containerization/vminit:<version>`), so
        /// discover that entry instead of pinning a version or guessing the
        /// `vminit:latest` short-name.
        static func discoverVminitReference(in storeRoot: URL) throws -> String {
            let stateURL = storeRoot.appendingPathComponent("state.json")
            guard let data = try? Data(contentsOf: stateURL),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                throw ValidationError(
                    "vminit initfs not found: no state.json in the container system store at \(storeRoot.path). "
                        + "Start the Apple container system first (`container system start`) or pass --initfs.")
            }
            for key in dict.keys where key.split(separator: "/").last?.hasPrefix("vminit") == true {
                return key
            }
            throw ValidationError(
                "vminit initfs not registered in the container system store at \(storeRoot.path). "
                    + "Start the Apple container system first (`container system start`) or pass --initfs.")
        }
    }
}
#else
extension WWNContainerd {
    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "run")
        func run() async throws {
            throw ValidationError(
                "wwn-containerd requires macOS (Apple Containerization framework). "
                    + "On other targets use the container-in-VM backend via wwn-vms.")
        }
    }
}
#endif
