// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "editxr",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .executableTarget(
            name: "editxr"
        ),
    ]
)
