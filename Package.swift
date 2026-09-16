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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4")
    ],
    targets: [
        .binaryTarget(
            name: "CLibXMP",
            path: "Vendor/LibXMP.xcframework"
        ),
        .executableTarget(
            name: "ModRadio",
            dependencies: ["CLibXMP", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ],
    swiftLanguageModes: [.v5]
)
