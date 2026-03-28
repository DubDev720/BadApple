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

private struct Detection {
    let source: String
}

private struct RingBuffer {
    private var data: [Double]
    private var pos = 0
    private var full = false

    init(capacity: Int) {
        self.data = Array(repeating: 0, count: capacity)
    }

    mutating func push(_ value: Double) {
        data[pos] = value
        pos += 1
        if pos >= data.count {
            pos = 0
            full = true
        }
    }

    var count: Int {
        full ? data.count : pos
    }

    func values() -> [Double] {
        if !full {
            return Array(data.prefix(pos))
        }
        return Array(data[pos...]) + Array(data[..<pos])
    }
}

private final class SampleDetector {
    private let sampleRate = 100.0
    private let hpAlpha = 0.95
    private let staN = [3.0, 15.0, 50.0]
    private let ltaN = [100.0, 500.0, 2000.0]
    private let staLTAOn = [3.0, 2.5, 2.0]
    private let staLTAOff = [1.5, 1.3, 1.2]
    private let cusumK = 0.0005
    private let cusumH = 0.01

    private var hpPrevRaw = (0.0, 0.0, 0.0)
    private var hpPrevOut = (0.0, 0.0, 0.0)
    private var hpReady = false

    private var sta = [0.0, 0.0, 0.0]
    private var lta = [1e-10, 1e-10, 1e-10]
    private var staLTAActive = [false, false, false]

    private var cusumPos = 0.0
    private var cusumNeg = 0.0
    private var cusumMu = 0.0

    private var kurtosisBuffer = RingBuffer(capacity: 100)
    private var peakBuffer = RingBuffer(capacity: 200)
    private var sampleCount = 0
    private var kurtDecimation = 0
    private var lastEventTime = 0.0

    func process(_ sample: SensorSampleEnvelope) -> SlapEventEnvelope? {
        sampleCount += 1
        let tNow = Double(sample.timestampUnixNano) / 1_000_000_000.0

        if !hpReady {
            hpPrevRaw = (sample.x, sample.y, sample.z)
            hpReady = true
            return nil
        }

        let hx = hpAlpha * (hpPrevOut.0 + sample.x - hpPrevRaw.0)
        let hy = hpAlpha * (hpPrevOut.1 + sample.y - hpPrevRaw.1)
        let hz = hpAlpha * (hpPrevOut.2 + sample.z - hpPrevRaw.2)
        hpPrevRaw = (sample.x, sample.y, sample.z)
        hpPrevOut = (hx, hy, hz)

        let magnitude = sqrt(hx * hx + hy * hy + hz * hz)
        var detections: [Detection] = []

        let energy = magnitude * magnitude
        for index in 0..<3 {
            sta[index] += (energy - sta[index]) / staN[index]
            lta[index] += (energy - lta[index]) / ltaN[index]
            let ratio = sta[index] / (lta[index] + 1e-30)
            if ratio > staLTAOn[index] && !staLTAActive[index] {
                staLTAActive[index] = true
                detections.append(Detection(source: "STA/LTA"))
            } else if ratio < staLTAOff[index] {
                staLTAActive[index] = false
            }
        }

        cusumMu += 0.0001 * (magnitude - cusumMu)
        cusumPos = max(0, cusumPos + magnitude - cusumMu - cusumK)
        cusumNeg = max(0, cusumNeg - magnitude + cusumMu - cusumK)
        if cusumPos > cusumH {
            detections.append(Detection(source: "CUSUM"))
            cusumPos = 0
        }
        if cusumNeg > cusumH {
            detections.append(Detection(source: "CUSUM"))
            cusumNeg = 0
        }

        kurtosisBuffer.push(magnitude)
        kurtDecimation += 1
        if kurtDecimation >= 10 && kurtosisBuffer.count >= 50 {
            kurtDecimation = 0
            let values = kurtosisBuffer.values()
            let mean = values.reduce(0, +) / Double(values.count)
            var m2 = 0.0
            var m4 = 0.0
            for value in values {
                let delta = value - mean
                let deltaSquared = delta * delta
                m2 += deltaSquared
                m4 += deltaSquared * deltaSquared
            }
            m2 /= Double(values.count)
            m4 /= Double(values.count)
            let kurtosis = m4 / (m2 * m2 + 1e-30)
            if kurtosis > 6 {
                detections.append(Detection(source: "KURTOSIS"))
            }
        }

        peakBuffer.push(magnitude)
        if peakBuffer.count >= 50 && sampleCount % 10 == 0 {
            let values = peakBuffer.values().sorted()
            let n = values.count
            let median = values[n / 2]
            let deviations = values.map { abs($0 - median) }.sorted()
            let mad = deviations[n / 2]
            let sigma = 1.4826 * mad + 1e-30
            if abs(magnitude - median) / sigma > 2.0 {
                detections.append(Detection(source: "PEAK"))
            }
        }

        if detections.isEmpty || (tNow - lastEventTime) <= 0.01 {
            return nil
        }
        lastEventTime = tNow
        return classify(detections: detections, tNow: tNow, amplitude: magnitude)
    }

    private func classify(detections: [Detection], tNow: Double, amplitude: Double) -> SlapEventEnvelope {
        let sourceSet = Set(detections.map(\.source))
        let severity: String
        switch true {
        case sourceSet.count >= 4 && amplitude > 0.05:
            severity = "CHOC_MAJEUR"
        case sourceSet.count >= 3 && amplitude > 0.02:
            severity = "CHOC_MOYEN"
        case sourceSet.contains("PEAK") && amplitude > 0.005:
            severity = "MICRO_CHOC"
        case (sourceSet.contains("STA/LTA") || sourceSet.contains("CUSUM")) && amplitude > 0.003:
            severity = "VIBRATION"
        case amplitude > 0.001:
            severity = "VIB_LEGERE"
        default:
            severity = "MICRO_VIB"
        }

        return SlapEventEnvelope(
            type: "slap",
            amplitude: amplitude,
            severity: severity,
            timestampUnixNano: Int64(tNow * 1_000_000_000.0)
        )
    }
}

enum SensorDetectorError: Error, CustomStringConvertible {
    case usage(String)
    case invalidInput(String)

    var description: String {
        switch self {
        case .usage(let value), .invalidInput(let value):
            return value
        }
    }
}

private func runDetect() throws {
    let detector = SampleDetector()
    while let line = readLine() {
        if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            continue
        }
        let data = Data(line.utf8)
        let sample = try JSONDecoder().decode(SensorSampleEnvelope.self, from: data)
        guard sample.type == "sample" else {
            throw SensorDetectorError.invalidInput("expected sample event, got \(sample.type)")
        }
        if let event = detector.process(sample) {
            try emitJSONLine(event)
        }
    }
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else {
        throw SensorDetectorError.usage("usage: sensor-detector detect")
    }
    switch command {
    case "detect":
        try runDetect()
    case "help", "-h", "--help":
        throw SensorDetectorError.usage("usage: sensor-detector detect")
    default:
        throw SensorDetectorError.usage("unknown command \(command)")
    }
} catch let error as SensorDetectorError {
    fputs("\(error.description)\n", stderr)
    exit(1)
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
