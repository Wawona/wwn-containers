//===----------------------------------------------------------------------===//
// wwn-containerd-spike — Wawona Phase A spike (desktop in containers).
//
// Boots an OCI container (Apple Containerization framework) whose process is a
// guest waypipe server bound to a vsock port, then:
//   1. dialVsock(port)      — the only way to reach a container vsock from the
//                             host process (no /dev/vsock on macOS)
//   2. dup the fd into R,W  — sockets are full-duplex
//   3. spawn the host waypipe client on those fds (--socket-fds R,W), which
//      attaches to Wawona's compositor via the inherited WAYLAND_DISPLAY
//
// Guest topology: waypipe --no-gpu --vsock -s <port> server -- /session.sh <mode>
//   mode=flower -> weston-flower   (vsock direction test)
//   mode=kwin   -> kwin_wayland --platform wayland  (nested compositor test)
//
// Spike code: the working parts land in wwn-containerd proper during Phase B.
//===----------------------------------------------------------------------===//

import ArgumentParser
import Containerization
import ContainerizationError
import ContainerizationOCI
import ContainerizationOS
import Darwin
import Foundation

@main
struct WWNContainerSpike: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wwn-containerd-spike",
        abstract: "Phase A spike: container + guest waypipe server over vsock + host waypipe client over raw fds"
    )

    @Option(name: [.customLong("image"), .customShort("i")],
            help: "OCI image reference (loaded into the Apple container image store)")
    var imageReference: String = "wawona-plasma-guest-spike"

    @Option(name: .customLong("mode"), help: "Guest session mode: flower | kwin")
    var mode: String = "flower"

    @Option(name: [.customLong("kernel"), .customShort("k")], help: "Linux kernel image path (default: auto-discovered under the app root)")
    var kernel: String?

    @Option(name: .customLong("initfs"), help: "Prebuilt vminitd ext4 initfs path (default: <app-root>/initfs.ext4)")
    var initfs: String?

    @Option(name: .customLong("app-root"), help: "Apple container system app-data root (default: ~/Library/Application Support/com.apple.container)")
    var appRoot: String?

    @Option(name: .customLong("vsock-port"), help: "Guest vsock port the waypipe server binds")
    var vsockPort: UInt32 = 1024

    @Option(name: .customLong("waypipe-bin"), help: "Host waypipe binary (patched with a working --socket-fds)")
    var waypipeBin: String?

    @Option(name: [.customLong("cpus"), .customShort("c")], help: "vCPUs")
    var cpus: Int = 2

    @Option(name: [.customLong("memory"), .customShort("m")], help: "Memory (MiB)")
    var memory: UInt64 = 2048

    @Option(name: .customLong("fs-size"), help: "Rootfs block size (MiB)")
    var fsSizeInMB: UInt64 = 8192

    @Flag(name: .customLong("rosetta"), help: "Enable Rosetta x86_64 emulation")
    var rosetta = false

    mutating func run() async throws {
        let appRootURL = Self.resolveAppRoot(appRoot)
        let kernelPath = try resolveKernel(appRootURL)
        let initfsPath = try resolveInitfs(appRootURL)

        Self.log("[spike] image=\(imageReference) mode=\(mode)")
        Self.log("[spike] kernel=\(kernelPath)")
        Self.log("[spike] initfs=\(initfsPath)")

        let kernel = Kernel(
            path: URL(fileURLWithPath: kernelPath),
            platform: .linuxArm
        )

        let network: Network?
        if #available(macOS 26, *) {
            network = try VmnetNetwork()
        } else {
            network = nil
        }

        let initMount = Mount.block(
            format: "ext4",
            source: initfsPath,
            destination: "/",
            options: ["ro"]
        )
        var manager = try ContainerManager(
            kernel: kernel,
            initfs: initMount,
            network: network,
            rosetta: rosetta
        )

        // The container's process IS the guest waypipe server. waypipe exports
        // its own fake Wayland socket to /session.sh via WAYLAND_DISPLAY.
        let guestArgs = [
            "waypipe", "--no-gpu", "--vsock", "-s", "\(vsockPort)",
            "server", "--", "/session.sh", mode,
        ]

        let id = "wawona-spike"
        let container = try await manager.create(
            id,
            reference: imageReference,
            rootfsSizeInBytes: UInt64(fsSizeInMB) * 1024 * 1024,
            readOnly: false,
            networking: true
        ) { config in
            config.cpus = cpus
            config.memoryInBytes = memory * 1024 * 1024
            config.process.arguments = guestArgs
            config.process.workingDirectory = "/"
            config.useInit = true
            // Mirrors wwn-containerd --wayland-vsock-port: the guest session
            // gets a writable runtime dir; waypipe overrides WAYLAND_DISPLAY
            // for its child.
            config.process.environmentVariables.append("WAYLAND_DISPLAY=wayland-0")
            config.process.environmentVariables.append("XDG_RUNTIME_DIR=/run/user/0")
        }
        Self.log("[spike] creating container…")
        try await container.create()
        Self.log("[spike] starting container…")
        try await container.start()

        // 1. Dial the vsock port the guest waypipe server binds. Retry: the
        //    guest may not have bound yet when the VM finishes starting.
        var vsockHandle: FileHandle?
        for attempt in 1...60 {
            do {
                let h = try await container.dialVsock(port: vsockPort)
                vsockHandle = h
                break
            } catch {
                if attempt == 60 { throw error }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        guard let handle = vsockHandle else {
            throw ValidationError("dialVsock returned nil")
        }
        Self.log("[spike] dialVsock(\(vsockPort)) -> fd \(handle.fileDescriptor)")

        // 2. Dup the full-duplex socket fd into the R,W pair waypipe expects.
        let base = handle.fileDescriptor
        let rfd = dup(base)
        let wfd = dup(base)
        guard rfd >= 0, wfd >= 0 else {
            throw ValidationError("dup failed: \(String(cString: strerror(errno)))")
        }
        Self.log("[spike] waypipe fds R=\(rfd) W=\(wfd)")

        // 3. Spawn the host waypipe client on those fds. The dup'd fds carry
        //    no CLOEXEC flag, so Process inherits them; WAYLAND_DISPLAY and
        //    XDG_RUNTIME_DIR pass through to Wawona's compositor.
        let waypipePath = waypipeBin
            ?? ProcessInfo.processInfo.environment["WWNP_WAYPIPE_BIN"]
            ?? "waypipe"
        let waypipeProc = Process()
        waypipeProc.executableURL = URL(fileURLWithPath: waypipePath)
        waypipeProc.arguments = ["--socket-fds", "\(rfd),\(wfd)", "client"]
        Self.log("[spike] spawning \(waypipePath) --socket-fds \(rfd),\(wfd) client")
        try waypipeProc.run()

        // Ctrl-C / SIGTERM: kill the waypipe client; container.wait() keeps
        // running until the guest process exits, then teardown below runs.
        let signalQueue = DispatchQueue(label: "wawona-spike.signals")
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
            source.setEventHandler {
                Self.log("[spike] signal received — terminating waypipe client")
                waypipeProc.terminate()
            }
            source.resume()
        }

        // 4. Wait for the guest session to end (window closed / session exit).
        let exit = try await container.wait()
        Self.log("[spike] container exited: \(exit.exitCode)")

        if waypipeProc.isRunning {
            waypipeProc.terminate()
            waypipeProc.waitUntilExit()
        }
        try await container.stop()
        try manager.delete(id)
        Self.log("[spike] done")
    }

    // MARK: - helpers

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    /// The Apple container system's app-data root. Mirrors wwn-containerd.
    static func resolveAppRoot(_ flagValue: String?) -> URL {
        if let raw = flagValue, !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        }
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return support.appendingPathComponent("com.apple.container")
    }

    /// Find a LinuxArm kernel under <app-root>/kernels.
    func resolveKernel(_ appRootURL: URL) throws -> String {
        if let kernel, !kernel.isEmpty {
            return (kernel as NSString).expandingTildeInPath
        }
        let dir = appRootURL.appendingPathComponent("kernels")
        let preferred = ["default.kernel-arm64", "wawona-vmlinux-arm64"]
        for name in preferred {
            let p = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: p.path) { return p.path }
        }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard let first = entries.first else {
            throw ValidationError("no kernel found under \(dir.path) — pass --kernel")
        }
        return dir.appendingPathComponent(first).path
    }

    /// The prebuilt vminitd ext4 initfs (container system stores one at
    /// <app-root>/initfs.ext4).
    func resolveInitfs(_ appRootURL: URL) throws -> String {
        if let initfs, !initfs.isEmpty {
            return (initfs as NSString).expandingTildeInPath
        }
        let p = appRootURL.appendingPathComponent("initfs.ext4")
        guard FileManager.default.fileExists(atPath: p.path) else {
            throw ValidationError("no initfs at \(p.path) — pass --initfs")
        }
        return p.path
    }
}
