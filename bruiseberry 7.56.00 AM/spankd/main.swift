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

private let severityFloor = 0.0
private let severityCeiling = 1.0

private struct Clip {
    let name: String
    let path: String
}

private struct SlapTracker {
    var score: Double
    var lastTime: Date
}

private enum NativeDaemonError: Error, CustomStringConvertible {
    case usage(String)
    case invalidArgument(String)
    case config(String)
    case io(String)
    case protocolError(String)
    case playback(String)

    var description: String {
        switch self {
        case .usage(let message),
             .invalidArgument(let message),
             .config(let message),
             .io(let message),
             .protocolError(let message),
             .playback(let message):
            return message
        }
    }
}

private final class RuntimeState {
    private let lock = NSLock()
    private var config: RuntimeConfig
    private var paused = false

    init(config: RuntimeConfig) {
        self.config = config
    }

    func snapshot() -> (RuntimeConfig, Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (config, paused)
    }

    func setPaused(_ paused: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.paused = paused
    }

    func applyConfig(_ config: RuntimeConfig) {
        lock.lock()
        defer { lock.unlock() }
        self.config = config
    }
}

private final class MediaLibrary {
    private let assetsDir: String
    private let packsDir: String
    private var embeddedClips = [String: [Clip]]()
    private var runtimeClips = [String: [Clip]]()

    init(assetsDir: String, packsDir: String) throws {
        self.assetsDir = assetsDir
        self.packsDir = packsDir
        try reload()
    }

    func reload() throws {
        embeddedClips.removeAll()
        runtimeClips.removeAll()

        try loadEmbedded(source: "sexy", required: true)
        try loadEmbedded(source: "custom", required: false)
        try loadRuntimePacks()
    }

    func validateSelection(source: String, strategy: String) throws {
        if source.isEmpty {
            throw NativeDaemonError.config("source is required")
        }
        switch strategy {
        case "random", "escalation":
            break
        default:
            throw NativeDaemonError.config("unsupported strategy \(strategy)")
        }
        if source == "chaos", strategy != "random" {
            throw NativeDaemonError.config("source \"chaos\" only supports strategy \"random\"")
        }
        _ = try clips(for: source)
    }

    func randomClip(for source: String) throws -> Clip {
        let clips = try clips(for: source)
        guard let clip = clips.randomElement() else {
            throw NativeDaemonError.config("source \(source) has no clips")
        }
        return clip
    }

    func escalationClip(for source: String, score: Double, cooldownMs: Int) throws -> Clip {
        let clips = try clips(for: source)
        if clips.count <= 1 {
            guard let clip = clips.first else {
                throw NativeDaemonError.config("source \(source) has no clips")
            }
            return clip
        }

        let decayHalfLife = 30.0
        let cooldownSeconds = Double(cooldownMs) / 1000.0
        let steadyStateMax = 1.0 / (1.0 - pow(0.5, cooldownSeconds / decayHalfLife))
        let scale = (steadyStateMax - 1.0) / log(Double(clips.count + 1))
        let maxIndex = clips.count - 1
        var index = Int(Double(clips.count) * (1.0 - exp(-(score - 1.0) / scale)))
        if index < 0 {
            index = 0
        }
        if index > maxIndex {
            index = maxIndex
        }
        return clips[index]
    }

    private func clips(for source: String) throws -> [Clip] {
        if source == "chaos" {
            let clips = embeddedClips
                .filter { $0.key != "chaos" }
                .flatMap { $0.value }
            if clips.isEmpty {
                throw NativeDaemonError.config("source \"chaos\" has no clips")
            }
            return clips
        }
        if let clips = embeddedClips[source], !clips.isEmpty {
            return clips
        }
        if let clips = runtimeClips[source], !clips.isEmpty {
            return clips
        }
        throw NativeDaemonError.config("source \(source) has no clips")
    }

    private func loadEmbedded(source: String, required: Bool) throws {
        let dir = URL(fileURLWithPath: assetsDir, isDirectory: true).appendingPathComponent(source, isDirectory: true)
        guard let clips = try loadClipDirectory(dir.path) else {
            if required {
                throw NativeDaemonError.config("embedded source \(source) has no clips")
            }
            return
        }
        embeddedClips[source] = clips
    }

    private func loadRuntimePacks() throws {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: packsDir, isDirectory: true), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return
        }
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                continue
            }
            let name = normalizeSourceName(entry.lastPathComponent)
            try validateRuntimePackName(name)
            if let clips = try loadClipDirectory(entry.path) {
                runtimeClips[name] = clips
            }
        }
    }

    private func loadClipDirectory(_ path: String) throws -> [Clip]? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: path, isDirectory: true), includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        let wavEntries = entries
            .filter { $0.pathExtension.lowercased() == "wav" }
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        if wavEntries.isEmpty {
            return nil
        }
        try validateSequentialClipNames(wavEntries)
        let clips = try wavEntries.map { url -> Clip in
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true else {
                    throw NativeDaemonError.config("clip \(url.path) is not a regular file")
                }
                if let fileSize = values.fileSize, fileSize <= 0 {
                    throw NativeDaemonError.config("clip \(url.path) is empty")
                }
                try validateCanonicalWAV(at: url)
                return Clip(name: url.lastPathComponent, path: url.path)
            }
        return clips
    }
}

private final class AudioHelperClient {
    private let helperPath: String

    init(helperPath: String) {
        self.helperPath = helperPath
    }

    func play(clipPath: String, rate: Double, volume: Double) throws {
        let request = PlaybackRequest(clipPath: clipPath, rate: rate, volume: volume)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helperPath)
        process.arguments = ["play"]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let requestData = try makeJSONEncoder().encode(request)
        stdinPipe.fileHandleForWriting.write(requestData)
        stdinPipe.fileHandleForWriting.closeFile()

        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        guard !stdoutData.isEmpty else {
            let stderr = String(decoding: stderrData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw NativeDaemonError.playback("audio-helper produced no response (\(stderr))")
        }

        let response = try makeJSONDecoder().decode(ToolResponse.self, from: stdoutData)
        guard response.status == "ok" else {
            throw NativeDaemonError.playback(response.error ?? "audio-helper returned \(response.status)")
        }
        if process.terminationStatus != 0 {
            throw NativeDaemonError.playback("audio-helper exited with status \(process.terminationStatus)")
        }
    }
}

private final class UnixSocketServer {
    typealias RequestHandler = (Data) -> Data?

    private let path: String
    private let handler: RequestHandler
    private let acceptQueue: DispatchQueue
    private let workerQueue: DispatchQueue
    private var listenFD: Int32 = -1
    private var running = false

    init(path: String, label: String, handler: @escaping RequestHandler) {
        self.path = path
        self.handler = handler
        self.acceptQueue = DispatchQueue(label: "\(label).accept")
        self.workerQueue = DispatchQueue(label: "\(label).worker", attributes: .concurrent)
    }

    func start() throws {
        try createSocket()
        running = true
        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        running = false
        if listenFD >= 0 {
            Darwin.shutdown(listenFD, SHUT_RDWR)
            Darwin.close(listenFD)
            listenFD = -1
        }
        unlink(path)
    }

    private func createSocket() throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: (path as NSString).deletingLastPathComponent, isDirectory: true),
            withIntermediateDirectories: true
        )

        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NativeDaemonError.io("socket \(path): \(posixErrorDescription())")
        }

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
            Darwin.close(fd)
            throw NativeDaemonError.io("socket path too long: \(path)")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePointer in
            let rawPointer = UnsafeMutableRawPointer(tuplePointer).assumingMemoryBound(to: CChar.self)
            for (index, byte) in bytes.enumerated() {
                rawPointer[index] = byte
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let message = posixErrorDescription()
            Darwin.close(fd)
            throw NativeDaemonError.io("bind \(path): \(message)")
        }
        guard listen(fd, SOMAXCONN) == 0 else {
            let message = posixErrorDescription()
            Darwin.close(fd)
            throw NativeDaemonError.io("listen \(path): \(message)")
        }
        guard chmod(path, 0o660) == 0 else {
            let message = posixErrorDescription()
            Darwin.close(fd)
            throw NativeDaemonError.io("chmod \(path): \(message)")
        }
        listenFD = fd
    }

    private func acceptLoop() {
        while running {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if !running {
                    return
                }
                if errno == EINTR {
                    continue
                }
                usleep(100_000)
                continue
            }
            workerQueue.async { [weak self] in
                self?.handle(clientFD: clientFD)
            }
        }
    }

    private func handle(clientFD: Int32) {
        defer { Darwin.close(clientFD) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let readCount = read(clientFD, &buffer, buffer.count)
            if readCount < 0 {
                return
            }
            if readCount == 0 {
                break
            }
            data.append(buffer, count: readCount)
            if data.firstIndex(of: 0x0a) != nil {
                break
            }
        }
        guard let newlineIndex = data.firstIndex(of: 0x0a) else {
            return
        }
        let payload = data.prefix(upTo: newlineIndex)
        guard let response = handler(Data(payload)) else {
            return
        }
        _ = response.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }
            return writeAll(clientFD: clientFD, bytes: baseAddress, count: response.count)
        }
    }

    private func writeAll(clientFD: Int32, bytes: UnsafePointer<UInt8>, count: Int) -> Int {
        var total = 0
        while total < count {
            let result = Darwin.write(clientFD, bytes.advanced(by: total), count - total)
            if result <= 0 {
                return total
            }
            total += result
        }
        return total
    }
}

private final class NativeDaemon {
    private let configPath: String
    private let eventSocketPath: String
    private let controlSocketPath: String
    private let mediaLibrary: MediaLibrary
    private let audioHelper: AudioHelperClient
    private let state: RuntimeState
    private let eventQueue = DispatchQueue(label: "spankd.events")

    private var trackers = [String: SlapTracker]()
    private var lastPlayback = Date.distantPast
    private var eventServer: UnixSocketServer?
    private var controlServer: UnixSocketServer?

    init(
        configPath: String,
        runtimeDir: String,
        assetsDir: String,
        packsDir: String,
        audioHelperPath: String
    ) throws {
        self.configPath = configPath
        self.eventSocketPath = URL(fileURLWithPath: runtimeDir, isDirectory: true).appendingPathComponent("spankd.sock").path
        self.controlSocketPath = URL(fileURLWithPath: runtimeDir, isDirectory: true).appendingPathComponent("spankctl.sock").path
        self.mediaLibrary = try MediaLibrary(assetsDir: assetsDir, packsDir: packsDir)
        self.audioHelper = AudioHelperClient(helperPath: audioHelperPath)

        let initialConfig: RuntimeConfig
        do {
            initialConfig = try loadConfig(path: configPath)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            initialConfig = defaultRuntimeConfig()
        } catch {
            throw error
        }
        try validateRuntimeConfig(initialConfig, validateSelection: mediaLibrary.validateSelection)
        self.state = RuntimeState(config: initialConfig)
    }

    func start() throws {
        eventServer = UnixSocketServer(path: eventSocketPath, label: "spankd.events") { [weak self] data in
            self?.handleEventRequest(data: data)
            return nil
        }
        controlServer = UnixSocketServer(path: controlSocketPath, label: "spankd.control") { [weak self] data in
            self?.handleControlRequest(data: data)
        }
        try eventServer?.start()
        try controlServer?.start()
        log("ready event_socket=\(eventSocketPath) control_socket=\(controlSocketPath)")
    }

    func stop() {
        eventServer?.stop()
        controlServer?.stop()
    }

    func reloadFromDisk() throws {
        try mediaLibrary.reload()
        let config = try loadConfig(path: configPath)
        try validateRuntimeConfig(config, validateSelection: mediaLibrary.validateSelection)
        state.applyConfig(config)
        log("reloaded config path=\(configPath)")
    }

    private func handleEventRequest(data: Data) {
        eventQueue.async {
            do {
                let envelope = try makeJSONDecoder().decode(EventEnvelope.self, from: data)
                try self.validate(envelope: envelope)
                switch envelope.type {
                case "slap":
                    guard let slap = envelope.slap else {
                        throw NativeDaemonError.protocolError("slap event missing payload")
                    }
                    try self.handle(slap: slap)
                case "health":
                    if let health = envelope.health {
                        self.log("helper_health msg=\"\(health.message)\"")
                    }
                case "error":
                    if let helperError = envelope.helperError {
                        self.log("helper_error msg=\"\(helperError.message)\"")
                    }
                default:
                    throw NativeDaemonError.protocolError("unsupported event type \(envelope.type)")
                }
            } catch {
                self.log("event_rejected err=\(error)")
            }
        }
    }

    private func handleControlRequest(data: Data) -> Data {
        let response: ControlResponse
        do {
            let request = try makeJSONDecoder().decode(ControlRequest.self, from: data)
            response = try runControlRequest(request)
        } catch {
            let current = state.snapshot()
            response = ControlResponse(
                status: "error",
                error: String(describing: error),
                config: current.0,
                paused: current.1
            )
        }
        let encoded = (try? makeJSONEncoder().encode(response)) ?? Data("{\"status\":\"error\",\"error\":\"encode response\"}\n".utf8)
        var line = encoded
        line.append(0x0a)
        return line
    }

    private func runControlRequest(_ request: ControlRequest) throws -> ControlResponse {
        switch request.command {
        case "pause":
            state.setPaused(true)
        case "resume":
            state.setPaused(false)
        case "reload":
            try reloadFromDisk()
        case "update":
            let current = state.snapshot().0
            let updated = try apply(update: request.update, to: current)
            try validate(config: updated)
            try saveConfig(path: configPath, config: updated)
            state.applyConfig(updated)
        case "status":
            break
        default:
            throw NativeDaemonError.protocolError("unknown command \(request.command)")
        }

        let snapshot = state.snapshot()
        return ControlResponse(status: "ok", error: nil, config: snapshot.0, paused: snapshot.1)
    }

    private func handle(slap: SlapPayload) throws {
        try validate(slap: slap)
        let (config, paused) = state.snapshot()
        if paused || slap.amplitude < config.minAmplitude {
            return
        }
        let cooldown = TimeInterval(config.cooldownMs) / 1000.0
        if Date().timeIntervalSince(lastPlayback) <= cooldown {
            return
        }

        let clip: Clip
        switch config.strategy {
        case "random":
            clip = try mediaLibrary.randomClip(for: config.source)
        case "escalation":
            let score = recordScore(source: config.source, now: slap.timestamp)
            clip = try mediaLibrary.escalationClip(for: config.source, score: score, cooldownMs: config.cooldownMs)
        default:
            throw NativeDaemonError.config("unsupported strategy \(config.strategy)")
        }

        let volume = playbackVolume(amplitude: slap.amplitude, scaled: config.volumeScaling)
        try audioHelper.play(clipPath: clip.path, rate: config.speedRatio, volume: volume)
        lastPlayback = Date()
        log("played source=\(config.source) strategy=\(config.strategy) clip=\(clip.name) amplitude=\(String(format: "%.4f", slap.amplitude)) severity=\(slap.severity ?? "")")
    }

    private func recordScore(source: String, now: Date) -> Double {
        let halfLife = 30.0
        var tracker = trackers[source] ?? SlapTracker(score: 0, lastTime: .distantPast)
        if tracker.lastTime != .distantPast {
            let elapsed = now.timeIntervalSince(tracker.lastTime)
            tracker.score *= pow(0.5, elapsed / halfLife)
        }
        tracker.score += 1.0
        tracker.lastTime = now
        trackers[source] = tracker
        return tracker.score
    }

    private func validate(envelope: EventEnvelope) throws {
        switch envelope.type {
        case "slap":
            guard envelope.slap != nil else {
                throw NativeDaemonError.protocolError("slap event missing payload")
            }
            guard envelope.health == nil, envelope.helperError == nil else {
                throw NativeDaemonError.protocolError("slap event contains extra payloads")
            }
        case "health":
            guard envelope.health != nil else {
                throw NativeDaemonError.protocolError("health event missing payload")
            }
            guard envelope.slap == nil, envelope.helperError == nil else {
                throw NativeDaemonError.protocolError("health event contains extra payloads")
            }
        case "error":
            guard envelope.helperError != nil else {
                throw NativeDaemonError.protocolError("error event missing payload")
            }
            guard envelope.slap == nil, envelope.health == nil else {
                throw NativeDaemonError.protocolError("error event contains extra payloads")
            }
        default:
            throw NativeDaemonError.protocolError("unsupported event type \(envelope.type)")
        }
    }

    private func validate(slap: SlapPayload) throws {
        guard slap.timestamp.timeIntervalSince1970 > 0 else {
            throw NativeDaemonError.protocolError("slap event missing timestamp")
        }
        guard slap.amplitude.isFinite else {
            throw NativeDaemonError.protocolError("slap amplitude must be finite")
        }
        guard slap.amplitude >= severityFloor, slap.amplitude <= severityCeiling else {
            throw NativeDaemonError.protocolError("slap amplitude \(slap.amplitude) out of range")
        }
    }

    private func validate(config: RuntimeConfig) throws {
        do {
            try validateRuntimeConfig(config, validateSelection: mediaLibrary.validateSelection)
        } catch {
            throw NativeDaemonError.config(String(describing: error))
        }
    }

    private func apply(update: ConfigUpdate?, to current: RuntimeConfig) throws -> RuntimeConfig {
        guard let update else {
            throw NativeDaemonError.protocolError("update command missing update payload")
        }
        let next = RuntimeConfig(
            source: normalizeSourceName(update.source ?? current.source),
            strategy: normalizeStrategyName(update.strategy ?? current.strategy),
            minAmplitude: update.minAmplitude ?? current.minAmplitude,
            cooldownMs: update.cooldownMs ?? current.cooldownMs,
            speedRatio: update.speedRatio ?? current.speedRatio,
            volumeScaling: update.volumeScaling ?? current.volumeScaling
        )
        return normalizeLegacy(next)
    }

    private func log(_ message: String) {
        fputs("spankd: \(message)\n", stderr)
    }
}

private func loadConfig(path: String) throws -> RuntimeConfig {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let config = try makeJSONDecoder().decode(RuntimeConfig.self, from: data)
    return normalizeLegacy(config)
}

private func saveConfig(path: String, config: RuntimeConfig) throws {
    let normalized = normalizeLegacy(config)
    let data = try makeJSONEncoder().encode(normalized)
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var line = data
    line.append(0x0a)
    try line.write(to: url, options: .atomic)
}

private func playbackVolume(amplitude: Double, scaled: Bool) -> Double {
    guard scaled else {
        return 1.0
    }
    if amplitude <= 0 {
        return 0.35
    }
    if amplitude >= 1 {
        return 1.0
    }
    return 0.35 + amplitude * 0.65
}

private func posixErrorDescription() -> String {
    String(cString: strerror(errno))
}

private struct ParsedArguments {
    let runtimeDir: String
    let configPath: String
    let assetsDir: String
    let packsDir: String
    let audioHelperPath: String
}

private func parseArguments() throws -> ParsedArguments {
    var runtimeDir: String?
    var configPath: String?
    var assetsDir: String?
    var packsDir: String?
    var audioHelperPath: String?

    let args = Array(CommandLine.arguments.dropFirst())
    var index = 0
    while index < args.count {
        let arg = args[index]
        switch arg {
        case "-runtime-dir":
            index += 1
            guard index < args.count else { throw NativeDaemonError.invalidArgument("missing value for -runtime-dir") }
            runtimeDir = args[index]
        case "-config":
            index += 1
            guard index < args.count else { throw NativeDaemonError.invalidArgument("missing value for -config") }
            configPath = args[index]
        case "-assets-dir":
            index += 1
            guard index < args.count else { throw NativeDaemonError.invalidArgument("missing value for -assets-dir") }
            assetsDir = args[index]
        case "-packs-dir":
            index += 1
            guard index < args.count else { throw NativeDaemonError.invalidArgument("missing value for -packs-dir") }
            packsDir = args[index]
        case "-audio-helper":
            index += 1
            guard index < args.count else { throw NativeDaemonError.invalidArgument("missing value for -audio-helper") }
            audioHelperPath = args[index]
        case "-h", "--help", "help":
            throw NativeDaemonError.usage("usage: spankd -runtime-dir <dir> -config <file> [-assets-dir <dir>] [-packs-dir <dir>] [-audio-helper <path>]")
        default:
            throw NativeDaemonError.invalidArgument("unknown argument \(arg)")
        }
        index += 1
    }

    let executablePath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let binDir = executablePath.deletingLastPathComponent()
    let appSupportDir = binDir.deletingLastPathComponent()

    return ParsedArguments(
        runtimeDir: runtimeDir ?? appSupportDir.appendingPathComponent("run", isDirectory: true).path,
        configPath: configPath ?? appSupportDir.appendingPathComponent("config.json").path,
        assetsDir: assetsDir ?? appSupportDir.appendingPathComponent("assets", isDirectory: true).path,
        packsDir: packsDir ?? appSupportDir.appendingPathComponent("packs", isDirectory: true).path,
        audioHelperPath: audioHelperPath ?? binDir.appendingPathComponent("audio-helper").path
    )
}

private var signalSources = [DispatchSourceSignal]()

private func installSignalHandlers(daemon: NativeDaemon, terminate: @escaping () -> Void) {
    signal(SIGPIPE, SIG_IGN)
    for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
        source.setEventHandler {
            if signalNumber == SIGHUP {
                do {
                    try daemon.reloadFromDisk()
                } catch {
                    fputs("spankd: reload_failed err=\(error)\n", stderr)
                }
                return
            }
            daemon.stop()
            terminate()
        }
        source.resume()
        signalSources.append(source)
    }
}

do {
    let args = try parseArguments()
    let daemon = try NativeDaemon(
        configPath: args.configPath,
        runtimeDir: args.runtimeDir,
        assetsDir: args.assetsDir,
        packsDir: args.packsDir,
        audioHelperPath: args.audioHelperPath
    )
    try daemon.start()

    let semaphore = DispatchSemaphore(value: 0)
    installSignalHandlers(daemon: daemon) {
        semaphore.signal()
    }
    semaphore.wait()
} catch let error as NativeDaemonError {
    fputs("spankd: \(error.description)\n", stderr)
    exit(1)
} catch {
    fputs("spankd: \(error.localizedDescription)\n", stderr)
    exit(1)
}
