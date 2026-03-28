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

let canonicalSampleRate = 48_000
let canonicalChannels = 2
let canonicalBitDepth = 16
let maxClipDurationSeconds = 10

enum WAVValidationError: Error, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case .invalid(let message):
            return message
        }
    }
}

func validateSequentialClipNames(_ files: [URL]) throws {
    for (index, url) in files.enumerated() {
        let expected = String(format: "%02d.wav", index)
        if url.lastPathComponent != expected {
            throw WAVValidationError.invalid("expected canonical clip name \(expected), got \(url.lastPathComponent)")
        }
    }
}

func validateCanonicalWAV(at fileURL: URL) throws {
    let data = try Data(contentsOf: fileURL)
    try validateCanonicalWAVData(named: fileURL.lastPathComponent, data: data)
}

func validateCanonicalWAVData(named clipName: String, data: Data) throws {
    if data.count < 44 {
        throw WAVValidationError.invalid("validate clip \(clipName): clip too short for WAV header")
    }

    try data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            throw WAVValidationError.invalid("validate clip \(clipName): empty data")
        }

        func ascii(_ offset: Int, _ length: Int) -> String {
            String(decoding: UnsafeBufferPointer(start: base.advanced(by: offset), count: length), as: UTF8.self)
        }
        func u16(_ offset: Int) -> UInt16 {
            UInt16(base[offset]) | (UInt16(base[offset + 1]) << 8)
        }
        func u32(_ offset: Int) -> UInt32 {
            UInt32(base[offset]) |
            (UInt32(base[offset + 1]) << 8) |
            (UInt32(base[offset + 2]) << 16) |
            (UInt32(base[offset + 3]) << 24)
        }

        if ascii(0, 4) != "RIFF" {
            throw WAVValidationError.invalid("validate clip \(clipName): missing RIFF header")
        }
        if ascii(8, 4) != "WAVE" {
            throw WAVValidationError.invalid("validate clip \(clipName): missing WAVE signature")
        }

        let riffSize = Int(u32(4))
        if riffSize + 8 > data.count {
            throw WAVValidationError.invalid("validate clip \(clipName): RIFF size exceeds clip length")
        }

        var offset = 12
        var hasFmt = false
        var hasData = false
        var dataSize: UInt32 = 0
        var audioFormat: UInt16 = 0
        var channelCount: UInt16 = 0
        var sampleRate: UInt32 = 0
        var byteRate: UInt32 = 0
        var blockAlign: UInt16 = 0
        var bitsPerSample: UInt16 = 0

        while offset + 8 <= data.count {
            let chunkID = ascii(offset, 4)
            let chunkSize = Int(u32(offset + 4))
            offset += 8
            if offset + chunkSize > data.count {
                throw WAVValidationError.invalid("validate clip \(clipName): chunk \(chunkID) exceeds clip length")
            }
            switch chunkID {
            case "fmt ":
                hasFmt = true
                if chunkSize < 16 {
                    throw WAVValidationError.invalid("validate clip \(clipName): fmt chunk too small")
                }
                audioFormat = u16(offset)
                channelCount = u16(offset + 2)
                sampleRate = u32(offset + 4)
                byteRate = u32(offset + 8)
                blockAlign = u16(offset + 12)
                bitsPerSample = u16(offset + 14)
            case "data":
                hasData = true
                dataSize = UInt32(chunkSize)
            default:
                break
            }
            offset += chunkSize
            if chunkSize % 2 == 1, offset < data.count {
                offset += 1
            }
        }

        if !hasFmt {
            throw WAVValidationError.invalid("validate clip \(clipName): missing fmt chunk")
        }
        if !hasData || dataSize == 0 {
            throw WAVValidationError.invalid("validate clip \(clipName): missing data chunk")
        }
        if audioFormat != 1 {
            throw WAVValidationError.invalid("validate clip \(clipName): unsupported wav format \(audioFormat); expected PCM")
        }
        if channelCount != canonicalChannels {
            throw WAVValidationError.invalid("validate clip \(clipName): expected \(canonicalChannels) channels, got \(channelCount)")
        }
        if sampleRate != canonicalSampleRate {
            throw WAVValidationError.invalid("validate clip \(clipName): expected sample rate \(canonicalSampleRate), got \(sampleRate)")
        }
        if bitsPerSample != canonicalBitDepth {
            throw WAVValidationError.invalid("validate clip \(clipName): expected \(canonicalBitDepth)-bit audio, got \(bitsPerSample)")
        }

        let expectedBlockAlign = UInt16(canonicalChannels * (canonicalBitDepth / 8))
        if blockAlign != expectedBlockAlign {
            throw WAVValidationError.invalid("validate clip \(clipName): expected block align \(expectedBlockAlign), got \(blockAlign)")
        }
        let expectedByteRate = UInt32(canonicalSampleRate) * UInt32(expectedBlockAlign)
        if byteRate != expectedByteRate {
            throw WAVValidationError.invalid("validate clip \(clipName): expected byte rate \(expectedByteRate), got \(byteRate)")
        }
        if dataSize % UInt32(expectedBlockAlign) != 0 {
            throw WAVValidationError.invalid("validate clip \(clipName): data chunk is not aligned to \(expectedBlockAlign)-byte PCM frames")
        }
        let duration = Double(dataSize) / Double(expectedByteRate)
        if duration > Double(maxClipDurationSeconds) {
            throw WAVValidationError.invalid("validate clip \(clipName): clip exceeds max duration of \(maxClipDurationSeconds) seconds")
        }
    }
}
