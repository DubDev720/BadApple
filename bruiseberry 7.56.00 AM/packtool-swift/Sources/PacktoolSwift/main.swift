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

private let supportedExtensions = Set(["wav", "mp3", "m4a", "aac", "aif", "aiff", "caf"])

enum PacktoolError: Error, CustomStringConvertible {
    case usage(String)
    case invalidArgument(String)
    case invalidState(String)

    var description: String {
        switch self {
        case .usage(let message), .invalidArgument(let message), .invalidState(let message):
            return message
        }
    }
}

struct CLI {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            throw PacktoolError.usage(usageText)
        }

        switch command {
        case "normalize-dir":
            let parser = ArgumentParser(arguments: Array(args.dropFirst()))
            let sourceDir = try parser.value(for: ["-source-dir", "--source-dir"])
            let outputDir = try parser.value(for: ["-output-dir", "--output-dir"])
            try normalizeDir(sourceDir: sourceDir, outputDir: outputDir)
        case "validate-dir":
            let parser = ArgumentParser(arguments: Array(args.dropFirst()))
            let dir = try parser.value(for: ["-dir", "--dir"])
            try validateDir(path: dir)
        case "validate-embedded":
            let parser = ArgumentParser(arguments: Array(args.dropFirst()))
            let repoRoot = try parser.optionalValue(for: ["-repo-root", "--repo-root"]) ?? FileManager.default.currentDirectoryPath
            let includeCustom = parser.flagPresent(["-include-custom", "--include-custom"])
            try validateEmbedded(repoRoot: repoRoot, includeCustom: includeCustom)
        case "help", "-h", "--help":
            print(usageText)
        default:
            throw PacktoolError.usage("unknown command \(command)\n\n\(usageText)")
        }
    }

    static func normalizeDir(sourceDir: String, outputDir: String) throws {
        let sourceURL = URL(fileURLWithPath: sourceDir)
        let outputURL = URL(fileURLWithPath: outputDir)
        let inputFiles = try collectSupportedFiles(in: sourceURL)
        guard !inputFiles.isEmpty else {
            throw PacktoolError.invalidArgument("no supported audio files found in \(sourceDir)")
        }

        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        try removeExistingWAVs(in: outputURL)

        for (index, fileURL) in inputFiles.enumerated() {
            let targetURL = outputURL.appendingPathComponent(String(format: "%02d.wav", index))
            try convertFile(at: fileURL, to: targetURL)
            try validateCanonicalWAV(at: targetURL)
        }

        print("normalized \(inputFiles.count) files into \(outputDir)")
        print("canonical wav: \(Int(canonicalSampleRate)) Hz, \(canonicalBitDepth)-bit PCM, \(canonicalChannels) channels, max \(Int(maxClipDurationSeconds))s")
    }

    static func validateDir(path: String) throws {
        let dirURL = URL(fileURLWithPath: path)
        let wavFiles = try collectWAVFiles(in: dirURL)
        guard !wavFiles.isEmpty else {
            throw PacktoolError.invalidArgument("no .wav files found in \(path)")
        }
        try validateSequentialClipNames(wavFiles)
        for fileURL in wavFiles {
            try validateCanonicalWAV(at: fileURL)
        }
        print("validated \(wavFiles.count) canonical wav files in \(path)")
    }

    static func validateEmbedded(repoRoot: String, includeCustom: Bool) throws {
        let repoURL = URL(fileURLWithPath: repoRoot)
        let sexyDir = repoURL.appendingPathComponent("assets/sexy")
        try validateDir(path: sexyDir.path)

        if includeCustom {
            let customDir = repoURL.appendingPathComponent("assets/custom")
            try validateDir(path: customDir.path)
        }

        print("embedded media validated: \(Int(canonicalSampleRate)) Hz, \(canonicalBitDepth)-bit PCM, \(canonicalChannels) channels, max \(Int(maxClipDurationSeconds))s")
    }

    static func collectSupportedFiles(in directory: URL) throws -> [URL] {
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return entries
            .filter { url in
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                return !isDir.boolValue && supportedExtensions.contains(url.pathExtension.lowercased())
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func collectWAVFiles(in directory: URL) throws -> [URL] {
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return entries
            .filter { url in
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                return !isDir.boolValue && url.pathExtension.lowercased() == "wav"
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func removeExistingWAVs(in directory: URL) throws {
        for url in try collectWAVFiles(in: directory) {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func convertFile(at sourceURL: URL, to destinationURL: URL) throws {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        let inputFile = try AVAudioFile(forReading: sourceURL)
        let inputFormat = inputFile.processingFormat
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(canonicalSampleRate),
            channels: AVAudioChannelCount(canonicalChannels),
            interleaved: true
        ) else {
            throw PacktoolError.invalidState("could not create canonical output format")
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw PacktoolError.invalidState("could not create converter for \(sourceURL.path)")
        }

        let outputFile = try AVAudioFile(
            forWriting: destinationURL,
            settings: outputFormat.settings,
            commonFormat: outputFormat.commonFormat,
            interleaved: outputFormat.isInterleaved
        )

        let frameCapacity = AVAudioFrameCount(max(1024, inputFile.length))
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCapacity) else {
            throw PacktoolError.invalidState("could not allocate input buffer for \(sourceURL.path)")
        }
        try inputFile.read(into: inputBuffer)

        let outputCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * (Double(canonicalSampleRate) / inputFormat.sampleRate)) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            throw PacktoolError.invalidState("could not allocate output buffer for \(destinationURL.path)")
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
                throw PacktoolError.invalidState("conversion produced no audio for \(sourceURL.path)")
            }
            try outputFile.write(from: outputBuffer)
        case .error:
            throw PacktoolError.invalidState("conversion failed for \(sourceURL.path)")
        @unknown default:
            throw PacktoolError.invalidState("conversion returned unknown status for \(sourceURL.path)")
        }
    }

    static var usageText: String {
        """
        usage:
          packtool-swift normalize-dir -source-dir <dir> -output-dir <dir>
          packtool-swift validate-dir -dir <dir>
          packtool-swift validate-embedded [-repo-root <dir>] [--include-custom]
        """
    }
}

struct ArgumentParser {
    let arguments: [String]

    func value(for names: [String]) throws -> String {
        if let value = try optionalValue(for: names) {
            return value
        }
        throw PacktoolError.invalidArgument("missing required flag \(names.first ?? "")")
    }

    func optionalValue(for names: [String]) throws -> String? {
        for (index, arg) in arguments.enumerated() where names.contains(arg) {
            let nextIndex = index + 1
            guard nextIndex < arguments.count else {
                throw PacktoolError.invalidArgument("missing value for \(arg)")
            }
            return arguments[nextIndex]
        }
        return nil
    }

    func flagPresent(_ names: [String]) -> Bool {
        arguments.contains { names.contains($0) }
    }
}

do {
    try CLI.main()
} catch let error as PacktoolError {
    fputs("\(error)\n", stderr)
    exit(1)
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
