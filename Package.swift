// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MiniGit",
    platforms: [
        .iOS(.v14),
        .macOS(.v11)
    ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "XGit",
            targets: ["XGit"]),
        .library(
            name: "MiniGit",
            targets: ["MiniGit"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "XGit",
            dependencies: ["libgit2"],
            exclude: ["internal"]),
        .target(
            name: "MiniGit",
            dependencies: ["XGit"],
            linkerSettings: [.linkedLibrary("z"), .linkedLibrary("iconv")]),
        // libgit2 1.9.0 + OpenSSL 3.3.2 for iOS arm64
        // Replaces LibGit2-On-iOS v1.3.1 — fixes SecureTransport TLS failures on iOS 26/iPadOS 27
        .binaryTarget(
            name: "libgit2",
            path: "libgit2.xcframework"),
        .testTarget(
            name: "MiniGitTests",
            dependencies: ["MiniGit"]),
    ],
    cxxLanguageStandard: .cxx14
)
