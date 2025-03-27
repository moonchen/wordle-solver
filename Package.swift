// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "WordleSolver",
    platforms: [ // Specify minimum macOS version if needed
        .macOS(.v12) // Requires macOS 12+ for swift-atomics usually
    ],
    dependencies: [
        // Add the swift-atomics dependency
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.1.0") // Use latest appropriate version
    ],
    targets: [
        .executableTarget(
            name: "swift-wordle-solver",
            dependencies: [
                // Depend on the Atomics product
                .product(name: "Atomics", package: "swift-atomics")
            ]),
    ]
)