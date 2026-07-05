// swift-tools-version:6.0
//
// wwn-containerd — Wawona's macOS OCI execution backend, built on Apple's
// Containerization framework (per-container lightweight VM + vminitd, gRPC over
// vsock). Compiled on first run by containerd-bridge.nix using the host Swift
// toolchain + macOS SDK, so the Nix build stays pure (same model as wwn-vms'
// vz-launcher).
import PackageDescription

let package = Package(
    name: "wwn-containerd",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/containerization.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "wwn-containerd",
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
