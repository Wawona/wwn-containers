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

        // Run from a local OCI layout directory instead of resolving a registry
        // reference. Loads the image into the container system's image store
        // via ImageStore.load (the wwn-oci `import` command emits such a dir
        // next to the unpacked rootfs), then boots it.
        @Option(name: .customLong("image-archive"), help: "Path to a local OCI layout directory (overrides --image)")
        var imageArchive: String?

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
        // Desktop/Wayland bridge runs often pull clients inside the guest
        // (nixpkgs weston, etc.); 2 GiB fills during fetch.
        var fsSizeInMB: UInt64 = 8192

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

        // Prefer a relocatable guest tree (bin/ + lib/ with patchelf'd RPATH)
        // mounted once at /opt/wawona-waypipe. Avoids hundreds of virtiofs
        // shares for a nix store closure (Apple Containerization fails those).
        @Option(name: .customLong("waypipe-guest-root"), help: "Host directory with bin/waypipe + lib/ (mounted at /opt/wawona-waypipe)")
        var waypipeGuestRoot: String?

        // Fallback: newline-separated host nix store paths share-mounted at the
        // same absolute paths. Prefer --waypipe-guest-root. Auto-load
        // `<waypipe-guest-bin>.closure` / $WAWONA_WAYPIPE_GUEST_CLOSURE.
        @Option(name: .customLong("waypipe-guest-closure"), help: "File listing nix store paths to mount for guest waypipe")
        var waypipeGuestClosure: String?

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
                // Match Apple's `cctl run` macOS path: default image store +
                // `vminit:latest` (same store the system `container` CLI uses).
                manager = try await ContainerManager(
                    kernel: kernel,
                    initfsReference: "vminit:latest",
                    network: network,
                    rosetta: rosetta
                )
            }

            let useTTY = isatty(STDIN_FILENO) != 0
            let terminal: Terminal?
            if useTTY {
                let current = try Terminal.current
                try current.setraw()
                defer { current.tryReset() }
                terminal = current
            } else {
                terminal = nil
            }

            let port = waylandVsockPort

            // Local image from disk: load the OCI layout into the container
            // system's image store, then boot it by the reference the layout
            // registers (org.opencontainers.image.ref.name).
            let effectiveReference: String
            if let archive = imageArchive {
                let url = URL(fileURLWithPath: (archive as NSString).expandingTildeInPath)
                let loaded = try await manager.imageStore.load(from: url)
                guard let first = loaded.first else {
                    throw ValidationError("no image found in OCI layout at \(archive)")
                }
                effectiveReference = first.reference
            } else {
                effectiveReference = imageReference
            }

            // captureForPassthrough keeps a leading "--" that shells use to end
            // option parsing. Apple's vmexec would try to exec that token.
            var processArguments = arguments
            if processArguments.first == "--" {
                processArguments.removeFirst()
            }
            if processArguments.isEmpty {
                processArguments = ["/bin/sh"]
            }

            let container = try await manager.create(
                id,
                reference: effectiveReference,
                rootfsSizeInBytes: fsSizeInMB.mib(),
                readOnly: readOnly,
                networking: true
            ) { config in
                config.cpus = cpus
                config.memoryInBytes = memory.mib()
                if let terminal {
                    config.process.setTerminalIO(terminal: terminal)
                }
                config.process.arguments = processArguments
                config.process.workingDirectory = cwd
                config.useInit = self.`init`

                var hosts = Hosts.default
                if #available(macOS 26, *), !config.interfaces.isEmpty {
                    let interface = config.interfaces[0]
                    hosts.entries.append(
                        Hosts.Entry(
                            ipAddress: interface.ipv4Address.address.description,
                            hostnames: [id]
                        ))
                }
                config.hosts = hosts

                // Wawona Wayland bridge (guest side): inject the host's Linux
                // waypipe into the container as a read-only file mount and
                // wrap the command so ANY image runs its app through
                // `waypipe --vsock -s <port> server` — no special image needed.
                // The sh preamble creates XDG_RUNTIME_DIR (the C waypipe binds
                // its display socket there and never mkdir's; stock images
                // lack /run/user/0).
                if port != 0 {
                    let guestWaypipe = try Self.resolveGuestWaypipeBin(waypipeGuestBin)
                    let guestRoot = Self.resolveGuestWaypipeRoot(
                        flagValue: waypipeGuestRoot,
                        guestBin: guestWaypipe
                    )
                    let execPath: String
                    if let guestRoot {
                        // One share: relocatable tree with interpreter + libs.
                        config.mounts.append(.share(
                            source: guestRoot,
                            destination: "/opt/wawona-waypipe",
                            options: ["ro"]
                        ))
                        execPath = "/opt/wawona-waypipe/bin/waypipe"
                    } else {
                        let storeExec = Self.resolveGuestWaypipeStoreExec(guestWaypipe)
                        let closurePaths = try Self.resolveGuestWaypipeClosure(
                            flagValue: waypipeGuestClosure,
                            guestBin: guestWaypipe
                        )
                        for path in closurePaths {
                            config.mounts.append(.share(
                                source: path,
                                destination: path,
                                options: ["ro"]
                            ))
                        }
                        config.mounts.append(.share(
                            source: guestWaypipe,
                            destination: "/usr/local/bin/waypipe",
                            options: ["ro"]
                        ))
                        execPath = storeExec ?? "/usr/local/bin/waypipe"
                    }
                    // Oneshot + vsock: patched guest waypipe binds/listens so
                    // host dialVsock can connect (upstream oneshot server dials).
                    // -c none matches the host waypipe-fds client.
                    config.process.arguments =
                        [
                            "/bin/sh", "-c",
                            "mkdir -p \"$XDG_RUNTIME_DIR\" && chmod 0700 \"$XDG_RUNTIME_DIR\" && exec \"$@\"",
                            "wawona-waypipe",
                            execPath,
                            "--oneshot",
                            "--no-gpu",
                            "-c", "none",
                            "--vsock",
                            "-s", "\(port)",
                            "server",
                            "--",
                        ] + processArguments
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
            if let terminal {
                try? await container.resize(to: try terminal.size)
            }

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
            var relayPid: pid_t?
            var relayError: Error?
            if port != 0 {
                do {
                    relayPid = try await Self.startWaypipeRelay(container: container, port: port)
                } catch {
                    // Keep the guest alive long enough for stderr to flush, and
                    // surface the dial failure after wait() so wrapper debug is
                    // not lost when guest waypipe dies immediately.
                    relayError = error
                    fputs("waypipe relay failed: \(error)\n", stderr)
                }
            }

            let exit = try await container.wait()
            if let relayPid {
                Self.stopWaypipeRelay(pid: relayPid)
            }
            Self.writeMarkerFile(environmentKey: "WAWONA_CONTAINER_DONE_FILE")
            try await container.stop()
            if let relayError {
                throw relayError
            }
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

        /// Relocatable guest tree: flag / env / sibling `waypipe-guest-root`
        /// (or `<bin>-root`) containing `bin/waypipe`.
        static func resolveGuestWaypipeRoot(
            flagValue: String?,
            guestBin: String
        ) -> String? {
            var candidates: [String] = []
            if let raw = flagValue, !raw.isEmpty {
                candidates.append((raw as NSString).expandingTildeInPath)
            }
            if let env = ProcessInfo.processInfo.environment["WAWONA_WAYPIPE_GUEST_ROOT"],
               !env.isEmpty
            {
                candidates.append(env)
            }
            let fm = FileManager.default
            let binURL = URL(fileURLWithPath: guestBin)
            candidates.append(binURL.deletingLastPathComponent()
                .appendingPathComponent("waypipe-guest-root").path)
            candidates.append(guestBin + "-root")
            for path in candidates {
                let exec = (path as NSString).appendingPathComponent("bin/waypipe")
                if fm.isExecutableFile(atPath: exec) {
                    return path
                }
            }
            return nil
        }

        /// Optional original nix store path for the guest waypipe executable
        /// (`waypipe-guest.store` next to the copied binary). Prefer executing
        /// that path after mounting the closure so DT_NEEDED resolves.
        static func resolveGuestWaypipeStoreExec(_ guestBin: String) -> String? {
            let storeFile = guestBin + ".store"
            guard let raw = try? String(contentsOfFile: storeFile, encoding: .utf8) else {
                return nil
            }
            let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
                return nil
            }
            return path
        }

        /// Load newline-separated nix store paths to share-mount for the guest
        /// waypipe dynamic linker. Flag / env / sibling `.closure` file.
        static func resolveGuestWaypipeClosure(
            flagValue: String?,
            guestBin: String
        ) throws -> [String] {
            var filePath: String?
            if let raw = flagValue, !raw.isEmpty {
                filePath = (raw as NSString).expandingTildeInPath
            } else if let env = ProcessInfo.processInfo.environment["WAWONA_WAYPIPE_GUEST_CLOSURE"],
                      !env.isEmpty
            {
                filePath = env
            } else {
                let sibling = guestBin + ".closure"
                if FileManager.default.fileExists(atPath: sibling) {
                    filePath = sibling
                }
            }
            guard let filePath else { return [] }
            guard FileManager.default.fileExists(atPath: filePath) else {
                throw ValidationError("waypipe-guest-closure: no such file: \(filePath)")
            }
            let text = try String(contentsOfFile: filePath, encoding: .utf8)
            return text.split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) }
        }

        /// Dial the guest vsock port (retrying until the guest waypipe server
        /// binds) and spawn the host waypipe client on the raw fd pair.
        /// WAYLAND_DISPLAY/XDG_RUNTIME_DIR are inherited from the runner, so
        /// the client attaches to Wawona's compositor.
        static func startWaypipeRelay(
            container: LinuxContainer,
            port: UInt32
        ) async throws -> pid_t {
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

            // Guest waypipe binds vsock and writes the connection header after
            // the container process starts. Dial succeeding only means the port
            // is open; give the server a moment before the host client reads.
            try await Task.sleep(nanoseconds: 2_000_000_000)

            // Host waypipe uses `--socket-fds R,W client` in the child process.
            // Foundation.Process does not inherit arbitrary fds on macOS, so
            // map the dialed vsock into fixed child fds with posix_spawn.
            let base = handle.fileDescriptor
            Self.setBlockingFd(base)
            let rfd = dup(base)
            let wfd = dup(base)
            guard rfd >= 0, wfd >= 0 else {
                throw ValidationError("dup failed: \(String(cString: strerror(errno)))")
            }
            Self.setBlockingFd(rfd)
            Self.setBlockingFd(wfd)

            let waypipePath = ProcessInfo.processInfo.environment["WWNP_WAYPIPE_BIN"] ?? "waypipe"
            guard FileManager.default.isExecutableFile(atPath: waypipePath) else {
                throw ValidationError(
                    "waypipe not found or not executable at \(waypipePath). "
                        + "Set WWNP_WAYPIPE_BIN to the bundled waypipe-fds binary.")
            }

            // Fixed fds in the child; avoid stdin/stdout/stderr and low-number leaks.
            let childR: Int32 = 100
            let childW: Int32 = 101
            let fdArg = "\(childR),\(childW)"

            var fileActions: posix_spawn_file_actions_t?
            guard posix_spawn_file_actions_init(&fileActions) == 0 else {
                throw ValidationError("posix_spawn_file_actions_init failed")
            }
            defer { posix_spawn_file_actions_destroy(&fileActions) }

            posix_spawn_file_actions_adddup2(&fileActions, rfd, childR)
            posix_spawn_file_actions_adddup2(&fileActions, wfd, childW)
            posix_spawn_file_actions_addclose(&fileActions, rfd)
            posix_spawn_file_actions_addclose(&fileActions, wfd)

            var argv: [UnsafeMutablePointer<CChar>?] = [
                strdup(waypipePath),
                strdup("-n"),
                strdup("-c"),
                strdup("none"),
                strdup("--socket-fds"),
                strdup(fdArg),
                strdup("client"),
                nil,
            ]
            defer {
                for ptr in argv {
                    if let ptr { free(ptr) }
                }
            }

            var pid: pid_t = 0
            let spawnErr = argv.withUnsafeMutableBufferPointer { buf in
                posix_spawn(&pid, waypipePath, &fileActions, nil, buf.baseAddress, environ)
            }
            if spawnErr != 0 {
                throw ValidationError(
                    "posix_spawn \(waypipePath): \(String(cString: strerror(spawnErr)))")
            }

            FileHandle.standardError.write(Data(
                ("[wwn-containerd] waypipe client on vsock port \(port) "
                    + "(fd \(base), pid \(pid), --socket-fds \(fdArg))\n").utf8))
            return pid
        }

        static func stopWaypipeRelay(pid: pid_t) {
            guard pid > 0 else { return }
            if kill(pid, 0) != 0 { return }
            _ = kill(pid, SIGTERM)
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
        }

        private static func setBlockingFd(_ fd: Int32) {
            var flags = fcntl(fd, F_GETFL)
            if flags >= 0 {
                flags &= ~O_NONBLOCK
                _ = fcntl(fd, F_SETFL, flags)
            }
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
