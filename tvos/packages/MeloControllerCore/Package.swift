// swift-tools-version: 5.5
//
// tvOS subset of stossy11/Melo-Controller (GPL-3.0, commit b16a8e3).
//
// The MeloNX core sources import `Melo_Controller` only for two plain types:
// `VirtualControllerButton` and the `Controller` protocol. The rest of the
// package is the on-screen touch controller and its layout editor, which tvOS
// has no use for. Same product and module name, so the core files compile
// unchanged.

import PackageDescription

let package = Package(
    name: "Melo-Controller",
    platforms: [
        .iOS(.v15),
        .tvOS(.v16),
    ],
    products: [
        .library(name: "Melo-Controller", targets: ["Melo-Controller"]),
    ],
    targets: [
        .target(name: "Melo-Controller"),
    ]
)
