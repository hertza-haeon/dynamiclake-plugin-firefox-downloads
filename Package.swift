// swift-tools-version: 6.2

// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import PackageDescription

// Firefox Downloads, a DynamicLake plugin, in Swift. No package from anyone
// else: only Swift and what macOS itself carries.
//
// macOS 14 is the oldest macOS DynamicLake itself runs on.
let package = Package(
    name: "FirefoxDownloads",
    platforms: [.macOS(.v14)],
    products: [
        // What DynamicLake starts (the `executable` of plugin.json).
        .executable(name: "firefox-downloads", targets: ["FirefoxDownloadsCLI"]),
    ],
    targets: [
        // Everything the plugin does, so that all of it can be tested.
        .target(name: "FirefoxDownloadsKit", linkerSettings: [.linkedLibrary("z")]),
        // The program itself: reads its arguments and runs the kit.
        .executableTarget(name: "FirefoxDownloadsCLI", dependencies: ["FirefoxDownloadsKit"]),
        .testTarget(name: "FirefoxDownloadsKitTests", dependencies: ["FirefoxDownloadsKit"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v6]
)
