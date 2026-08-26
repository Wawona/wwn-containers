// swift-tools-version:6.0
//
// wwn-containerd-spike — Phase A spike: boot a container whose guest waypipe
// server binds a vsock port, dial it from the host, and attach the host
// waypipe client over the raw fds (--socket-fds). Spike code; the working
// parts land in wwn-containerd proper during Phase B.
import PackageDescription

let package = Package(
    name: "wwn-containerd-spike",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/containerization.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "wwn-containerd-spike",
            dependencies: [
                // ContainerizationError ships inside the Containerization library
                // product (its own module, not a separate product), so importing
                // `ContainerizationError` works without listing it here.
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        )
    ]
)
