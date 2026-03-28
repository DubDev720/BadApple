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

import AVFoundation
import Foundation

enum AudioHelperError: Error, CustomStringConvertible {
    case usage(String)
    case invalidRequest(String)
    case playback(String)

    var description: String {
        switch self {
        case .usage(let message), .invalidRequest(let message), .playback(let message):
            return message
        }
    }
}

func emit(_ response: ToolResponse, code: Int32) -> Never {
    try? emitJSONLine(response)
    exit(code)
}

func readRequest() throws -> PlaybackRequest {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    if data.isEmpty {
        throw AudioHelperError.invalidRequest("missing request body")
    }
    return try JSONDecoder().decode(PlaybackRequest.self, from: data)
}

func validate(_ request: PlaybackRequest) throws {
    guard request.rate > 0 else {
        throw AudioHelperError.invalidRequest("rate must be greater than 0")
    }
    guard request.volume >= 0, request.volume <= 1 else {
        throw AudioHelperError.invalidRequest("volume must be between 0 and 1")
    }
    guard request.clipPath.hasSuffix(".wav") else {
        throw AudioHelperError.invalidRequest("clip path must end with .wav")
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: request.clipPath, isDirectory: &isDirectory), !isDirectory.boolValue else {
        throw AudioHelperError.invalidRequest("clip path does not exist")
    }
}

func play(_ request: PlaybackRequest) throws {
    try validate(request)

    let url = URL(fileURLWithPath: request.clipPath)
    let data: Data
    do {
        data = try Data(contentsOf: url)
    } catch {
        throw AudioHelperError.playback("load data: \(error.localizedDescription)")
    }
    let player: AVAudioPlayer
    do {
        player = try AVAudioPlayer(data: data)
    } catch {
        throw AudioHelperError.playback("init player: \(error.localizedDescription)")
    }
    guard player.duration > 0 else {
        throw AudioHelperError.playback("failed to initialize AVAudioPlayer")
    }

    player.volume = Float(request.volume)
    player.enableRate = true
    player.rate = Float(request.rate)

    guard player.play() else {
        throw AudioHelperError.playback("AVAudioPlayer failed to start playback")
    }

    while player.isPlaying {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else {
        throw AudioHelperError.usage("usage: audio-helper play")
    }
    switch command {
    case "play":
        let request = try readRequest()
        try play(request)
        emit(ToolResponse(status: "ok", error: nil), code: 0)
    case "help", "-h", "--help":
        throw AudioHelperError.usage("usage: audio-helper play")
    default:
        throw AudioHelperError.usage("unknown command \(command)")
    }
} catch let error as AudioHelperError {
    emit(ToolResponse(status: "error", error: error.description), code: 1)
} catch {
    emit(ToolResponse(status: "error", error: error.localizedDescription), code: 1)
}
