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

import Darwin
import Foundation

private let daemonLabel = "com.spank.spankd"
private let helperLabel = "com.spank.spank-sensor-helper"

private let usage = """
badapple manages the running spank services.

Quick start:
  badapple status                    Show mode, sensitivity, and service state
  badapple mode sexy random          Set source and strategy
  badapple sensitivity medium        Set a named sensitivity preset
  badapple pack list                 Show installed runtime packs
  badapple resume                    Re-enable slap reactions after pause

Commands:
  help                               Show this help menu
  status                             Show daemon status and current settings
  pause                              Disable slap reactions without stopping services
  resume                             Re-enable slap reactions after pause
  reload                             Reload config.json into the daemon
  mode <source> [strategy]           Set source and optional strategy
  sensitivity <preset|number>        Set min-amplitude by label or exact number
  set [flags]                        Update one or more runtime settings
  pack <list|install|remove>         Manage optional runtime WAV packs
  detector <status|native>           Show native detector status
  start                              Start the LaunchAgent services
  stop                               Stop the LaunchAgent services
  restart                            Restart the LaunchAgent services

Mode reference:
  Sources:     sexy, chaos, custom, <runtime-pack-name>
  Strategies:  random, escalation
  Valid pairs:
    sexy    -> random | escalation
    chaos   -> random
    custom  -> random | escalation
    runtime -> random | escalation

Sensitivity reference:
  high    -> min-amplitude 0.23
  medium  -> min-amplitude 0.28
  low     -> min-amplitude 0.33
  numeric -> exact min-amplitude value from 0.0 to 1.0

Set flags:
  -source <sexy|chaos|custom|runtime-pack-name>
  -strategy <random|escalation>
  -min-amplitude <0.0-1.0>
  -cooldown <ms>
  -speed <ratio>
  -volume-scaling <true|false>

Examples:
  badapple status
  badapple mode sexy escalation
  badapple mode chaos
  badapple sensitivity high
  badapple sensitivity 0.26
  badapple set -cooldown 500 -speed 1.1
  badapple pack install afterglow ~/Downloads/afterglow-wavs
  badapple pack remove afterglow
  badapple detector status
  badapple detector native
  badapple pause
  badapple resume
  badapple restart
"""

private enum BadAppleError: Error, CustomStringConvertible {
    case usage(String)
    case invalidArgument(String)
    case io(String)
    case launchctl(String)
    case control(String)

    var description: String {
        switch self {
        case .usage(let message),
             .invalidArgument(let message),
             .io(let message),
             .launchctl(let message),
             .control(let message):
            return message
        }
    }
}

private struct Options {
    var runtimeDir: String
    var launchAgentsDir: String
    var packsDir: String
    var json = false
}

private enum Mode {
    case help
    case status
    case daemon(ControlRequest, humanName: String)
    case packList
    case packInstall(String, String)
    case packRemove(String)
    case detectorStatus
    case detectorNative
    case start
    case stop
    case restart
}

private struct ParsedCommand {
    let mode: Mode
    var options: Options
    let legacy: Bool
}

private func defaultHomeDirectory() -> URL {
    if let sudoUser = ProcessInfo.processInfo.environment["SUDO_USER"], !sudoUser.isEmpty {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dscl")
        process.arguments = [".", "-read", "/Users/\(sudoUser)", "NFSHomeDirectory"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let parts = output.split(separator: " ")
        if parts.count >= 2 {
            return URL(fileURLWithPath: String(parts[1]), isDirectory: true)
        }
    }
    return FileManager.default.homeDirectoryForCurrentUser
}

private func defaultOptions() -> Options {
    let home = defaultHomeDirectory()
    let appSupport = home.appendingPathComponent("Library/Application Support/spank", isDirectory: true)
    return Options(
        runtimeDir: appSupport.appendingPathComponent("run", isDirectory: true).path,
        launchAgentsDir: home.appendingPathComponent("Library/LaunchAgents", isDirectory: true).path,
        packsDir: appSupport.appendingPathComponent("packs", isDirectory: true).path,
        json: false
    )
}

private func parseSensitivityValue(_ value: String) throws -> Double {
    switch value.lowercased() {
    case "high":
        return sensitivityPresetHigh
    case "medium", "default":
        return sensitivityPresetMedium
    case "low":
        return sensitivityPresetLow
    default:
        guard let parsed = Double(value) else {
            throw BadAppleError.invalidArgument("invalid sensitivity \(value)")
        }
        return parsed
    }
}

private func parse(_ args: [String]) throws -> ParsedCommand {
    let options = defaultOptions()
    if args.isEmpty {
        return ParsedCommand(mode: .status, options: options, legacy: false)
    }
    if ["help", "-h", "--help"].contains(args[0]) {
        return ParsedCommand(mode: .help, options: options, legacy: false)
    }
    if args[0].hasPrefix("-") {
        return try parseLegacy(args, options: options)
    }
    return try parseSubcommand(args, options: options)
}

private func parseSubcommand(_ args: [String], options: Options) throws -> ParsedCommand {
    var options = options
    switch args[0] {
    case "status":
        try parseCommonFlags(Array(args.dropFirst()), options: &options)
        return ParsedCommand(mode: .status, options: options, legacy: false)
    case "pause", "resume", "reload":
        try parseCommonFlags(Array(args.dropFirst()), options: &options)
        return ParsedCommand(mode: .daemon(ControlRequest(command: args[0], update: nil), humanName: args[0]), options: options, legacy: false)
    case "mode":
        let remainder = try stripCommonFlags(Array(args.dropFirst()), options: &options)
        guard remainder.count == 1 || remainder.count == 2 else {
            throw BadAppleError.invalidArgument("mode requires <source> and optional [strategy]")
        }
        let update = ConfigUpdate(
            source: remainder[0],
            strategy: remainder.count == 2 ? remainder[1] : nil,
            minAmplitude: nil,
            cooldownMs: nil,
            speedRatio: nil,
            volumeScaling: nil
        )
        return ParsedCommand(mode: .daemon(ControlRequest(command: "update", update: update), humanName: "mode"), options: options, legacy: false)
    case "sensitivity":
        let remainder = try stripCommonFlags(Array(args.dropFirst()), options: &options)
        guard remainder.count == 1 else {
            throw BadAppleError.invalidArgument("sensitivity requires <low|medium|high|number>")
        }
        let value = try parseSensitivityValue(remainder[0])
        let update = ConfigUpdate(source: nil, strategy: nil, minAmplitude: value, cooldownMs: nil, speedRatio: nil, volumeScaling: nil)
        return ParsedCommand(mode: .daemon(ControlRequest(command: "update", update: update), humanName: "sensitivity"), options: options, legacy: false)
    case "set":
        let request = try parseSet(Array(args.dropFirst()), options: &options)
        return ParsedCommand(mode: .daemon(request, humanName: "set"), options: options, legacy: false)
    case "pack":
        let remainder = try stripPackFlags(Array(args.dropFirst()), options: &options)
        guard let action = remainder.first else {
            throw BadAppleError.invalidArgument("pack requires a subcommand: list|install|remove")
        }
        switch action {
        case "list":
            guard remainder.count == 1 else { throw BadAppleError.invalidArgument("pack list takes no additional arguments") }
            return ParsedCommand(mode: .packList, options: options, legacy: false)
        case "install":
            guard remainder.count == 3 else { throw BadAppleError.invalidArgument("pack install requires <name> <wav-dir>") }
            return ParsedCommand(mode: .packInstall(remainder[1], remainder[2]), options: options, legacy: false)
        case "remove":
            guard remainder.count == 2 else { throw BadAppleError.invalidArgument("pack remove requires <name>") }
            return ParsedCommand(mode: .packRemove(remainder[1]), options: options, legacy: false)
        default:
            throw BadAppleError.invalidArgument("unknown pack subcommand \(action)")
        }
    case "detector":
        let remainder = try stripCommonFlags(Array(args.dropFirst()), options: &options)
        guard remainder.count == 1 else {
            throw BadAppleError.invalidArgument("detector requires one action: status|native")
        }
        switch remainder[0] {
        case "status":
            return ParsedCommand(mode: .detectorStatus, options: options, legacy: false)
        case "native":
            return ParsedCommand(mode: .detectorNative, options: options, legacy: false)
        case "go":
            throw BadAppleError.invalidArgument("the installed helper is native-only; the legacy detector path is no longer available")
        default:
            throw BadAppleError.invalidArgument("unknown detector action \(remainder[0])")
        }
    case "start":
        try parseCommonFlags(Array(args.dropFirst()), options: &options)
        return ParsedCommand(mode: .start, options: options, legacy: false)
    case "stop":
        try parseCommonFlags(Array(args.dropFirst()), options: &options)
        return ParsedCommand(mode: .stop, options: options, legacy: false)
    case "restart":
        try parseCommonFlags(Array(args.dropFirst()), options: &options)
        return ParsedCommand(mode: .restart, options: options, legacy: false)
    default:
        throw BadAppleError.invalidArgument("unknown command \(args[0])")
    }
}

private func parseLegacy(_ args: [String], options: Options) throws -> ParsedCommand {
    var options = options
    var command = "status"
    var source: String?
    var strategy: String?
    var amplitude: Double?
    var cooldown: Int?
    var speed: Double?
    var volumeScaling: Bool?
    var includeVolumeScaling = false

    var index = 0
    while index < args.count {
        let arg = args[index]
        func nextValue() throws -> String {
            index += 1
            guard index < args.count else {
                throw BadAppleError.invalidArgument("missing value for \(arg)")
            }
            return args[index]
        }

        switch arg {
        case "-runtime-dir":
            options.runtimeDir = try nextValue()
        case "-launch-agents-dir":
            options.launchAgentsDir = try nextValue()
        case "-packs-dir":
            options.packsDir = try nextValue()
        case "-command":
            command = try nextValue()
        case "-source":
            source = try nextValue()
        case "-strategy":
            strategy = try nextValue()
        case "-min-amplitude":
            amplitude = Double(try nextValue())
        case "-cooldown":
            cooldown = Int(try nextValue())
        case "-speed":
            speed = Double(try nextValue())
        case "-volume-scaling":
            volumeScaling = (try nextValue()).lowercased() == "true"
        case "-set-volume-scaling":
            includeVolumeScaling = true
        case "-json":
            options.json = true
        case "-h", "--help":
            throw BadAppleError.usage(usage)
        default:
            throw BadAppleError.invalidArgument("unknown flag \(arg)")
        }
        index += 1
    }

    options.json = true
    if command == "update" {
        let update = ConfigUpdate(
            source: source,
            strategy: strategy,
            minAmplitude: amplitude,
            cooldownMs: cooldown,
            speedRatio: speed,
            volumeScaling: includeVolumeScaling ? volumeScaling : nil
        )
        return ParsedCommand(mode: .daemon(ControlRequest(command: command, update: update), humanName: "update"), options: options, legacy: true)
    }
    return ParsedCommand(mode: .daemon(ControlRequest(command: command, update: nil), humanName: command), options: options, legacy: true)
}

private func parseCommonFlags(_ args: [String], options: inout Options) throws {
    _ = try stripCommonFlags(args, options: &options)
}

private func stripCommonFlags(_ args: [String], options: inout Options) throws -> [String] {
    var positional = [String]()
    var index = 0
    while index < args.count {
        let arg = args[index]
        switch arg {
        case "-runtime-dir":
            index += 1
            guard index < args.count else { throw BadAppleError.invalidArgument("missing value for -runtime-dir") }
            options.runtimeDir = args[index]
        case "-launch-agents-dir":
            index += 1
            guard index < args.count else { throw BadAppleError.invalidArgument("missing value for -launch-agents-dir") }
            options.launchAgentsDir = args[index]
        case "-json":
            options.json = true
        default:
            positional.append(arg)
        }
        index += 1
    }
    return positional
}

private func stripPackFlags(_ args: [String], options: inout Options) throws -> [String] {
    var positional = [String]()
    var index = 0
    while index < args.count {
        let arg = args[index]
        switch arg {
        case "-packs-dir":
            index += 1
            guard index < args.count else { throw BadAppleError.invalidArgument("missing value for -packs-dir") }
            options.packsDir = args[index]
        default:
            positional.append(arg)
        }
        index += 1
    }
    return positional
}

private func parseSet(_ args: [String], options: inout Options) throws -> ControlRequest {
    var source: String?
    var strategy: String?
    var amplitude: Double?
    var cooldown: Int?
    var speed: Double?
    var volumeScaling: Bool?
    var index = 0
    while index < args.count {
        let arg = args[index]
        func nextValue() throws -> String {
            index += 1
            guard index < args.count else { throw BadAppleError.invalidArgument("missing value for \(arg)") }
            return args[index]
        }

        switch arg {
        case "-runtime-dir":
            options.runtimeDir = try nextValue()
        case "-source":
            source = try nextValue()
        case "-strategy":
            strategy = try nextValue()
        case "-min-amplitude":
            guard let value = Double(try nextValue()) else { throw BadAppleError.invalidArgument("invalid min-amplitude") }
            amplitude = value
        case "-cooldown":
            guard let value = Int(try nextValue()) else { throw BadAppleError.invalidArgument("invalid cooldown") }
            cooldown = value
        case "-speed":
            guard let value = Double(try nextValue()) else { throw BadAppleError.invalidArgument("invalid speed") }
            speed = value
        case "-volume-scaling":
            let value = try nextValue().lowercased()
            volumeScaling = (value == "true")
        default:
            throw BadAppleError.invalidArgument("unknown set flag \(arg)")
        }
        index += 1
    }
    guard source != nil || strategy != nil || amplitude != nil || cooldown != nil || speed != nil || volumeScaling != nil else {
        throw BadAppleError.invalidArgument("set requires at least one update flag")
    }
    return ControlRequest(command: "update", update: ConfigUpdate(
        source: source,
        strategy: strategy,
        minAmplitude: amplitude,
        cooldownMs: cooldown,
        speedRatio: speed,
        volumeScaling: volumeScaling
    ))
}

private func posixErrorDescription() -> String {
    String(cString: strerror(errno))
}

private func socketRequest(path: String, request: ControlRequest) throws -> ControlResponse {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw BadAppleError.io("socket: \(posixErrorDescription())")
    }
    defer { close(fd) }

    var value: Int32 = 1
    _ = withUnsafePointer(to: &value) {
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
    }

    var addr = sockaddr_un()
    #if os(macOS)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    #endif
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
    guard bytes.count <= maxLength else {
        throw BadAppleError.io("socket path too long: \(path)")
    }
    withUnsafeMutablePointer(to: &addr.sun_path) { tuplePointer in
        let rawPointer = UnsafeMutableRawPointer(tuplePointer).assumingMemoryBound(to: CChar.self)
        for (index, byte) in bytes.enumerated() {
            rawPointer[index] = byte
        }
    }
    let connectResult = withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connectResult == 0 else {
        throw BadAppleError.io("connect \(path): \(posixErrorDescription())")
    }

    var requestData = try makeJSONEncoder().encode(request)
    requestData.append(0x0a)
    try requestData.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
        var written = 0
        while written < requestData.count {
            let result = Darwin.write(fd, baseAddress.advanced(by: written), requestData.count - written)
            if result <= 0 {
                throw BadAppleError.io("write request: \(posixErrorDescription())")
            }
            written += result
        }
    }

    var responseData = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let readCount = read(fd, &buffer, buffer.count)
        if readCount < 0 {
            throw BadAppleError.io("read response: \(posixErrorDescription())")
        }
        if readCount == 0 {
            break
        }
        responseData.append(buffer, count: readCount)
        if responseData.firstIndex(of: 0x0a) != nil {
            break
        }
    }
    if let newlineIndex = responseData.firstIndex(of: 0x0a) {
        responseData = responseData.prefix(upTo: newlineIndex)
    }
    return try makeJSONDecoder().decode(ControlResponse.self, from: responseData)
}

private func launchctl(_ args: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = args
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let errorText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    if process.terminationStatus != 0 {
        let message = [output, errorText].joined().trimmingCharacters(in: .whitespacesAndNewlines)
        throw BadAppleError.launchctl(message.isEmpty ? "launchctl failed" : message)
    }
    return output
}

private func guiDomain() -> String {
    if let sudoUID = ProcessInfo.processInfo.environment["SUDO_UID"], let uid = Int(sudoUID) {
        return "gui/\(uid)"
    }
    return "gui/\(getuid())"
}

private func lookupServiceState(_ label: String) -> String {
    do {
        let output = try launchctl(["print", "\(guiDomain())/\(label)"])
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("state = ") {
                return String(trimmed.dropFirst("state = ".count))
            }
        }
        return "loaded"
    } catch {
        return "not loaded"
    }
}

private func bootstrapLaunchAgent(_ plistPath: String) throws {
    var lastError: Error?
    for _ in 0..<5 {
        do {
            _ = try launchctl(["bootstrap", guiDomain(), plistPath])
            return
        } catch {
            lastError = error
            Thread.sleep(forTimeInterval: 1.0)
        }
    }
    throw lastError ?? BadAppleError.launchctl("bootstrap failed")
}

private func bootoutIfPresent(_ label: String) throws {
    do {
        _ = try launchctl(["bootout", "\(guiDomain())/\(label)"])
    } catch let error as BadAppleError {
        if error.description.contains("Could not find service") || error.description.contains("No such process") || error.description.contains("Domain does not support specified action") {
            return
        }
        throw error
    }
}

private func printServiceSummary() {
    print("Daemon: \(lookupServiceState(daemonLabel))")
    print("Helper: \(lookupServiceState(helperLabel))")
}

private func printHumanStatus(_ runtimeDir: String, response: ControlResponse) {
    print("Daemon: \(lookupServiceState(daemonLabel))")
    print("Helper: \(lookupServiceState(helperLabel))")
    print("Helper detector: native")
    print("Runtime: \(runtimeDir)")
    guard let config = response.config else { return }
    print("Paused: \(response.paused)")
    print("Source: \(config.source)")
    print("Strategy: \(config.strategy)")
    let label = sensitivityLabel(config.minAmplitude)
    print("Sensitivity: \(label) (min-amplitude \(String(format: "%.3f", config.minAmplitude)))")
    print("Sensitivity presets: high=0.23 medium=0.28 low=0.33")
    print("Cooldown: \(config.cooldownMs)ms")
    print("Speed: \(String(format: "%.2f", config.speedRatio))x")
    print("Volume scaling: \(config.volumeScaling)")
}

private func printUnavailableStatus(_ runtimeDir: String) throws {
    print("Daemon: \(lookupServiceState(daemonLabel))")
    print("Helper: \(lookupServiceState(helperLabel))")
    print("Helper detector: native")
    print("Runtime: \(runtimeDir)")
    print("Control: unavailable")
    throw BadAppleError.control("daemon control socket is unavailable")
}

private func printActionResult(name: String, response: ControlResponse) {
    guard let config = response.config else {
        print("\(name): ok")
        return
    }
    if name == "pause" || name == "resume" {
        print("\(name): ok (paused=\(response.paused))")
        return
    }
    print("\(name): ok")
    print("source=\(config.source) strategy=\(config.strategy) min_amplitude=\(String(format: "%.3f", config.minAmplitude)) cooldown_ms=\(config.cooldownMs) speed_ratio=\(String(format: "%.2f", config.speedRatio)) volume_scaling=\(config.volumeScaling) paused=\(response.paused)")
    print("sensitivity_presets high=0.23 medium=0.28 low=0.33")
}

private struct PackInfo {
    let name: String
    let clipCount: Int
    let path: String
}

private func listPacks(in packsDir: String) throws -> [PackInfo] {
    let url = URL(fileURLWithPath: packsDir, isDirectory: true)
    guard let entries = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
        return []
    }
    return try entries
        .filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
        .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        .map { dir in
            let clips = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))?
                .filter { $0.pathExtension.lowercased() == "wav" } ?? []
            return PackInfo(name: dir.lastPathComponent, clipCount: clips.count, path: dir.path)
        }
}

private func installPack(packsDir: String, name: String, sourceDir: String) throws -> PackInfo {
    let normalized = normalizeSourceName(name)
    do {
        try validateRuntimePackName(normalized)
    } catch {
        throw BadAppleError.invalidArgument(String(describing: error))
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: sourceDir, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw BadAppleError.invalidArgument("source path \(sourceDir) is not a directory")
    }
    let targetDir = URL(fileURLWithPath: packsDir, isDirectory: true).appendingPathComponent(normalized, isDirectory: true)
    try FileManager.default.createDirectory(at: targetDir.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: targetDir)
    try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

    let packtool = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("packtool-swift").path
    let process = Process()
    process.executableURL = URL(fileURLWithPath: packtool)
    process.arguments = ["normalize-dir", "-source-dir", sourceDir, "-output-dir", targetDir.path]
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        let errorText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        throw BadAppleError.io(errorText.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    let clips = try FileManager.default.contentsOfDirectory(at: targetDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        .filter { $0.pathExtension.lowercased() == "wav" }
        .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    try validateSequentialClipNames(clips)
    for clip in clips {
        try validateCanonicalWAV(at: clip)
    }
    return PackInfo(name: normalized, clipCount: clips.count, path: targetDir.path)
}

private func removePack(packsDir: String, name: String) throws {
    let normalized = normalizeSourceName(name)
    do {
        try validateRuntimePackName(normalized)
    } catch {
        throw BadAppleError.invalidArgument(String(describing: error))
    }
    let targetDir = URL(fileURLWithPath: packsDir, isDirectory: true).appendingPathComponent(normalized, isDirectory: true)
    try? FileManager.default.removeItem(at: targetDir)
}

do {
    let parsed = try parse(Array(CommandLine.arguments.dropFirst()))
    switch parsed.mode {
    case .help:
        print(usage)
    case .status:
        let socketPath = URL(fileURLWithPath: parsed.options.runtimeDir, isDirectory: true).appendingPathComponent("spankctl.sock").path
        do {
            let response = try socketRequest(path: socketPath, request: ControlRequest(command: "status", update: nil))
            if parsed.options.json {
                let data = try makeJSONEncoder().encode(response)
                print(String(decoding: data, as: UTF8.self))
            } else {
                printHumanStatus(parsed.options.runtimeDir, response: response)
            }
        } catch {
            try printUnavailableStatus(parsed.options.runtimeDir)
        }
    case .daemon(let request, let humanName):
        let socketPath = URL(fileURLWithPath: parsed.options.runtimeDir, isDirectory: true).appendingPathComponent("spankctl.sock").path
        let response = try socketRequest(path: socketPath, request: request)
        if parsed.options.json {
            let data = try makeJSONEncoder().encode(response)
            print(String(decoding: data, as: UTF8.self))
        } else {
            if let error = response.error {
                throw BadAppleError.control(error)
            }
            if humanName == "status" {
                printHumanStatus(parsed.options.runtimeDir, response: response)
            } else {
                printActionResult(name: humanName, response: response)
            }
        }
    case .packList:
        let infos = try listPacks(in: parsed.options.packsDir)
        print("Runtime packs dir: \(parsed.options.packsDir)")
        if infos.isEmpty {
            print("No runtime packs installed.")
        } else {
            for info in infos {
                print("- \(info.name) (\(info.clipCount) clips)")
            }
        }
    case .packInstall(let name, let sourceDir):
        let info = try installPack(packsDir: parsed.options.packsDir, name: name, sourceDir: sourceDir)
        print("Installed runtime pack \"\(info.name)\" with \(info.clipCount) clips.")
        print("Pack path: \(info.path)")
        print("Canonical wav: 48000 Hz, 16-bit PCM, 2 channels, max 10s")
        print("badapple mode \(info.name) random")
    case .packRemove(let name):
        try removePack(packsDir: parsed.options.packsDir, name: name)
        print("Removed runtime pack \"\(name)\".")
    case .detectorStatus:
        print("Helper detector: native")
    case .detectorNative:
        print("Helper detector set to native")
    case .start:
        try bootoutIfPresent(helperLabel)
        try bootoutIfPresent(daemonLabel)
        Thread.sleep(forTimeInterval: 1.0)
        try bootstrapLaunchAgent("\(parsed.options.launchAgentsDir)/\(daemonLabel).plist")
        try bootstrapLaunchAgent("\(parsed.options.launchAgentsDir)/\(helperLabel).plist")
        _ = try launchctl(["kickstart", "-k", "\(guiDomain())/\(daemonLabel)"])
        _ = try launchctl(["kickstart", "-k", "\(guiDomain())/\(helperLabel)"])
        printServiceSummary()
    case .stop:
        try bootoutIfPresent(helperLabel)
        try bootoutIfPresent(daemonLabel)
        printServiceSummary()
    case .restart:
        try bootoutIfPresent(helperLabel)
        try bootoutIfPresent(daemonLabel)
        Thread.sleep(forTimeInterval: 1.0)
        try bootstrapLaunchAgent("\(parsed.options.launchAgentsDir)/\(daemonLabel).plist")
        try bootstrapLaunchAgent("\(parsed.options.launchAgentsDir)/\(helperLabel).plist")
        _ = try launchctl(["kickstart", "-k", "\(guiDomain())/\(daemonLabel)"])
        _ = try launchctl(["kickstart", "-k", "\(guiDomain())/\(helperLabel)"])
        printServiceSummary()
    }
} catch let error as BadAppleError {
    if case .usage(let text) = error {
        print(text)
        exit(2)
    }
    fputs("\(error.description)\n", stderr)
    exit(1)
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
