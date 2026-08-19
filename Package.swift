// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ModRadio",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "ModRadio", targets: ["ModRadio"])
    ],
    targets: [
        .binaryTarget(
            name: "CLibXMP",
            path: "Vendor/LibXMP.xcframework"
        ),
        .executableTarget(
            name: "ModRadio",
            dependencies: ["CLibXMP"]
        )
    ],
    swiftLanguageModes: [.v5]
)
