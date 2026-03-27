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

enum ConversionError: Error {
    case invalidArguments
    case sourceURL(String)
    case targetFormat(String)
}

func convertFile(at sourcePath: String) throws {
    let sourceURL = URL(fileURLWithPath: sourcePath)
    let destinationURL = sourceURL.deletingPathExtension().appendingPathExtension("wav")
    if FileManager.default.fileExists(atPath: destinationURL.path) {
        try FileManager.default.removeItem(at: destinationURL)
    }

    let input = try AVAudioFile(forReading: sourceURL)
    let inputFormat = input.processingFormat
    guard let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: inputFormat.sampleRate,
        channels: inputFormat.channelCount,
        interleaved: true
    ) else {
        throw ConversionError.targetFormat(sourcePath)
    }
    guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
        throw ConversionError.targetFormat(sourcePath)
    }

    let output = try AVAudioFile(
        forWriting: destinationURL,
        settings: outputFormat.settings,
        commonFormat: outputFormat.commonFormat,
        interleaved: outputFormat.isInterleaved
    )

    let inputCapacity = AVAudioFrameCount(max(1024, input.length))
    guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputCapacity) else {
        throw ConversionError.sourceURL(sourcePath)
    }
    try input.read(into: inputBuffer)

    let outputCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * outputFormat.sampleRate / inputFormat.sampleRate) + 1024
    guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
        throw ConversionError.targetFormat(sourcePath)
    }

    var providedInput = false
    var conversionError: NSError?
    let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
        if providedInput {
            outStatus.pointee = .endOfStream
            return nil
        }
        providedInput = true
        outStatus.pointee = .haveData
        return inputBuffer
    }

    if let conversionError {
        throw conversionError
    }
    switch status {
    case .haveData, .inputRanDry, .endOfStream:
        if outputBuffer.frameLength == 0 {
            throw ConversionError.targetFormat(sourcePath)
        }
        try output.write(from: outputBuffer)
    case .error:
        throw ConversionError.targetFormat(sourcePath)
    @unknown default:
        throw ConversionError.targetFormat(sourcePath)
    }
}

let args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty {
    fputs("usage: swift convert_embedded_audio.swift <file.mp3> [file.mp3 ...]\n", stderr)
    throw ConversionError.invalidArguments
}

for path in args {
    try convertFile(at: path)
}
