// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Dictova",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Dictova", targets: ["Dictova"])
    ],
    targets: [
        .executableTarget(
            name: "Dictova",
            path: "Sources/Dictova",
            resources: [.copy("Resources/converter.py")]
        )
    ]
)
