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

            var manager = try await ContainerManager(
                kernel: kernel,
                initfsReference: "vminit:latest",
                network: network,
                rosetta: rosetta
            )

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
                // WAYLAND_DISPLAY/XDG_RUNTIME_DIR so a GUI app in-guest talks to
                // the waypipe server we expect to run on the vsock port below.
                if port != 0 {
                    config.process.environmentVariables.append("WAYLAND_DISPLAY=wayland-0")
                    config.process.environmentVariables.append("XDG_RUNTIME_DIR=/run/user/0")
                }
            }

            defer { try? manager.delete(id) }

            try await container.create()
            try await container.start()
            try? await container.resize(to: try current.size)

            if port != 0 {
                FileHandle.standardError.write(Data(
                    "[wwn-containerd] guest waypipe expected on vsock port \(port); bridge it into Wawona with waypipe client + socat\n".utf8))
            }

            let exit = try await container.wait()
            try await container.stop()
            if exit.exitCode != 0 {
                throw ExitCode(Int32(exit.exitCode))
            }
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
