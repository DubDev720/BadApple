/*
 * Copyright (C) 2026 Jocelyn Dubeau
 *
 * This file is part of BadApple (aka Spank 2.0).
 *
 * BadApple is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * BadApple is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with BadApple.  If not, see <https://www.gnu.org/licenses/>.
 */

// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Bruiseberry",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "audio-helper", targets: ["AudioHelper"]),
        .executable(name: "badapple", targets: ["BadappleCLI"]),
        .executable(name: "packtool-swift", targets: ["PacktoolSwift"]),
        .executable(name: "sensor-detector", targets: ["SensorDetector"]),
        .executable(name: "spank-sensor-helper", targets: ["SpankSensorHelper"]),
        .executable(name: "spankd", targets: ["SpankdNative"]),
    ],
    targets: [
        .target(
            name: "BruiseberryCommon",
            path: "common"
        ),
        .executableTarget(
            name: "AudioHelper",
            dependencies: ["BruiseberryCommon"],
            path: "audio-helper",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
            ]
        ),
        .executableTarget(
            name: "BadappleCLI",
            dependencies: ["BruiseberryCommon"],
            path: "badapple"
        ),
        .executableTarget(
            name: "PacktoolSwift",
            dependencies: ["BruiseberryCommon"],
            path: "packtool-swift",
            exclude: ["Package.swift"],
            sources: ["Sources/PacktoolSwift/main.swift"],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
            ]
        ),
        .executableTarget(
            name: "SensorDetector",
            dependencies: ["BruiseberryCommon"],
            path: "sensor-detector"
        ),
        .executableTarget(
            name: "SpankSensorHelper",
            dependencies: ["BruiseberryCommon"],
            path: "spank-sensor-helper"
        ),
        .executableTarget(
            name: "SpankdNative",
            dependencies: ["BruiseberryCommon"],
            path: "spankd"
        ),
    ]
)
