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

private enum SensorHelperError: Error, CustomStringConvertible {
    case usage(String)
    case invalidArgument(String)
    case io(String)
    case pipeline(String)

    var description: String {
        switch self {
        case .usage(let message),
             .invalidArgument(let message),
             .io(let message),
             .pipeline(let message):
            return message
        }
    }
}

private struct ParsedArguments {
    let runtimeDir: String
}

private func parseArguments() throws -> ParsedArguments {
    var runtimeDir: String?
    let args = Array(CommandLine.arguments.dropFirst())
    var index = 0
    while index < args.count {
        let arg = args[index]
        switch arg {
        case "-runtime-dir":
            index += 1
            guard index < args.count else { throw SensorHelperError.invalidArgument("missing value for -runtime-dir") }
            runtimeDir = args[index]
        case "-native-detector":
            break
        case "-go-detector":
            throw SensorHelperError.invalidArgument("the legacy detector path is no longer installed; use the native helper pipeline")
        case "-h", "--help", "help":
            throw SensorHelperError.usage("usage: spank-sensor-helper -runtime-dir <dir> [-native-detector]")
        default:
            throw SensorHelperError.invalidArgument("unknown argument \(arg)")
        }
        index += 1
    }

    let executablePath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let binDir = executablePath.deletingLastPathComponent()
    let appSupportDir = binDir.deletingLastPathComponent()
    return ParsedArguments(
        runtimeDir: runtimeDir ?? appSupportDir.appendingPathComponent("run", isDirectory: true).path
    )
}

private func log(_ message: String) {
    fputs("spank-sensor-helper: \(message)\n", stderr)
}

private func posixErrorDescription() -> String {
    String(cString: strerror(errno))
}

private func binaryPath(named name: String) -> String {
    let executablePath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    return executablePath.deletingLastPathComponent().appendingPathComponent(name).path
}

private func sendEvent(socketPath: String, event: EventEnvelope) throws {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw SensorHelperError.io("socket: \(posixErrorDescription())")
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

    let bytes = Array(socketPath.utf8CString)
    let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
    guard bytes.count <= maxLength else {
        throw SensorHelperError.io("socket path too long: \(socketPath)")
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
        throw SensorHelperError.io("connect \(socketPath): \(posixErrorDescription())")
    }

    var data = try makeJSONEncoder().encode(event)
    data.append(0x0a)
    try data.withUnsafeBytes { rawBuffer in
        guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
            return
        }
        var written = 0
        while written < data.count {
            let result = Darwin.write(fd, bytes.advanced(by: written), data.count - written)
            if result <= 0 {
                throw SensorHelperError.io("write event: \(posixErrorDescription())")
            }
            written += result
        }
    }
}

private func decodeSlapLine(_ line: String) throws -> SlapEventEnvelope {
    let data = Data(line.utf8)
    let event = try makeJSONDecoder().decode(SlapEventEnvelope.self, from: data)
    guard event.type == "slap" else {
        throw SensorHelperError.pipeline("unexpected detector event type \(event.type)")
    }
    return event
}

private final class PipelineRelay {
    private let runtimeDir: String
    private let streamPath = binaryPath(named: "sensor-stream")
    private let detectorPath = binaryPath(named: "sensor-detector")

    init(runtimeDir: String) {
        self.runtimeDir = runtimeDir
    }

    func run() throws {
        let socketPath = URL(fileURLWithPath: runtimeDir, isDirectory: true).appendingPathComponent("spankd.sock").path

        let stream = Process()
        stream.executableURL = URL(fileURLWithPath: streamPath)
        stream.arguments = ["samples"]
        let streamStdout = Pipe()
        let streamStderr = Pipe()
        stream.standardOutput = streamStdout
        stream.standardError = streamStderr

        let detector = Process()
        detector.executableURL = URL(fileURLWithPath: detectorPath)
        detector.arguments = ["detect"]
        detector.standardInput = streamStdout
        let detectorStdout = Pipe()
        let detectorStderr = Pipe()
        detector.standardOutput = detectorStdout
        detector.standardError = detectorStderr

        try stream.run()
        try detector.run()

        let stdoutHandle = detectorStdout.fileHandleForReading
        defer {
            stream.terminate()
            detector.terminate()
        }

        while let lineData = try stdoutHandle.readLineData(), !lineData.isEmpty {
            let line = String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                continue
            }
            let slap = try decodeSlapLine(line)
            let envelope = EventEnvelope(
                type: "slap",
                slap: SlapPayload(
                    amplitude: slap.amplitude,
                    severity: slap.severity,
                    timestamp: Date(timeIntervalSince1970: Double(slap.timestampUnixNano) / 1_000_000_000.0)
                ),
                health: nil,
                helperError: nil
            )
            do {
                try sendEvent(socketPath: socketPath, event: envelope)
            } catch {
                log("event_send_error err=\(error)")
                usleep(500_000)
            }
        }

        detector.waitUntilExit()
        stream.waitUntilExit()

        if detector.terminationStatus != 0 {
            let stderr = String(decoding: detectorStderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SensorHelperError.pipeline("sensor-detector exited with status \(detector.terminationStatus): \(stderr)")
        }
        if stream.terminationStatus != 0 {
            let stderr = String(decoding: streamStderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SensorHelperError.pipeline("sensor-stream exited with status \(stream.terminationStatus): \(stderr)")
        }
    }
}

private extension FileHandle {
    func readLineData() throws -> Data? {
        var data = Data()
        while true {
            let chunk = try self.read(upToCount: 1)
            guard let chunk else {
                return data.isEmpty ? nil : data
            }
            if chunk.isEmpty {
                return data.isEmpty ? nil : data
            }
            if chunk == Data([0x0a]) {
                return data
            }
            data.append(chunk)
        }
    }
}

private var signalSources = [DispatchSourceSignal]()

private func installSignalHandlers(terminate: @escaping () -> Void) {
    signal(SIGPIPE, SIG_IGN)
    for signalNumber in [SIGINT, SIGTERM] {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
        source.setEventHandler(handler: terminate)
        source.resume()
        signalSources.append(source)
    }
}

do {
    let args = try parseArguments()
    let relay = PipelineRelay(runtimeDir: args.runtimeDir)
    let queue = DispatchQueue.global()
    let semaphore = DispatchSemaphore(value: 0)

    installSignalHandlers {
        semaphore.signal()
    }

    queue.async {
        do {
            try relay.run()
        } catch {
            log("helper failed: \(error)")
        }
        semaphore.signal()
    }

    semaphore.wait()
} catch let error as SensorHelperError {
    fputs("spank-sensor-helper: \(error.description)\n", stderr)
    exit(1)
} catch {
    fputs("spank-sensor-helper: \(error.localizedDescription)\n", stderr)
    exit(1)
}
