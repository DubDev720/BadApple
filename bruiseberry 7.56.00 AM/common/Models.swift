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

import Foundation

private let jsonDateFormatterWithFractionalSeconds: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
}()

private let jsonDateFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter
}()

func makeJSONEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .custom { date, encoder in
        var container = encoder.singleValueContainer()
        try container.encode(jsonDateFormatterWithFractionalSeconds.string(from: date))
    }
    return encoder
}

func makeJSONDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if let parsed = jsonDateFormatterWithFractionalSeconds.date(from: value) ?? jsonDateFormatter.date(from: value) {
            return parsed
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported timestamp \(value)")
    }
    return decoder
}

struct PlaybackRequest: Codable {
    let clipPath: String
    let rate: Double
    let volume: Double

    enum CodingKeys: String, CodingKey {
        case clipPath = "clip_path"
        case rate
        case volume
    }
}

struct ToolResponse: Codable {
    let status: String
    let error: String?
}

struct RuntimeConfig: Codable {
    let source: String
    let strategy: String
    let minAmplitude: Double
    let cooldownMs: Int
    let speedRatio: Double
    let volumeScaling: Bool

    enum CodingKeys: String, CodingKey {
        case source
        case strategy
        case minAmplitude = "min_amplitude"
        case cooldownMs = "cooldown_ms"
        case speedRatio = "speed_ratio"
        case volumeScaling = "volume_scaling"
    }
}

struct ConfigUpdate: Codable {
    let source: String?
    let strategy: String?
    let minAmplitude: Double?
    let cooldownMs: Int?
    let speedRatio: Double?
    let volumeScaling: Bool?

    enum CodingKeys: String, CodingKey {
        case source
        case strategy
        case minAmplitude = "min_amplitude"
        case cooldownMs = "cooldown_ms"
        case speedRatio = "speed_ratio"
        case volumeScaling = "volume_scaling"
    }
}

struct ControlRequest: Codable {
    let command: String
    let update: ConfigUpdate?
}

struct ControlResponse: Codable {
    let status: String
    let error: String?
    let config: RuntimeConfig?
    let paused: Bool
}

struct SlapPayload: Codable {
    let amplitude: Double
    let severity: String?
    let timestamp: Date
}

struct HealthPayload: Codable {
    let message: String
    let timestamp: Date
}

struct HelperErrorPayload: Codable {
    let message: String
    let timestamp: Date
}

struct EventEnvelope: Codable {
    let type: String
    let slap: SlapPayload?
    let health: HealthPayload?
    let helperError: HelperErrorPayload?

    enum CodingKeys: String, CodingKey {
        case type
        case slap
        case health
        case helperError = "helper_error"
    }
}

struct SensorSampleEnvelope: Codable {
    let type: String
    let x: Double
    let y: Double
    let z: Double
    let timestampUnixNano: Int64

    enum CodingKeys: String, CodingKey {
        case type
        case x
        case y
        case z
        case timestampUnixNano = "timestamp_unix_nano"
    }
}

struct SlapEventEnvelope: Codable {
    let type: String
    let amplitude: Double
    let severity: String
    let timestampUnixNano: Int64

    enum CodingKeys: String, CodingKey {
        case type
        case amplitude
        case severity
        case timestampUnixNano = "timestamp_unix_nano"
    }
}

func emitJSONLine<T: Encodable>(_ value: T) throws {
    let encoder = makeJSONEncoder()
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0a]))
}
