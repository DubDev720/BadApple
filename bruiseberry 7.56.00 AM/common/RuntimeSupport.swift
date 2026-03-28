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

let defaultMinAmplitude = 0.28
let defaultCooldownMs = 750
let defaultSpeedRatio = 1.0
let defaultSource = "sexy"
let defaultStrategy = "random"

let sensitivityPresetHigh = 0.23
let sensitivityPresetMedium = 0.28
let sensitivityPresetLow = 0.33

func defaultRuntimeConfig() -> RuntimeConfig {
    RuntimeConfig(
        source: defaultSource,
        strategy: defaultStrategy,
        minAmplitude: defaultMinAmplitude,
        cooldownMs: defaultCooldownMs,
        speedRatio: defaultSpeedRatio,
        volumeScaling: false
    )
}

func normalizeSourceName(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

func normalizeStrategyName(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

func normalizeLegacy(_ config: RuntimeConfig) -> RuntimeConfig {
    var source = normalizeSourceName(config.source)
    var strategy = normalizeStrategyName(config.strategy)
    if source == "pain" || source == "halo" || source.isEmpty {
        source = defaultSource
    }
    if strategy.isEmpty {
        strategy = defaultStrategy
    }
    return RuntimeConfig(
        source: source,
        strategy: strategy,
        minAmplitude: config.minAmplitude,
        cooldownMs: config.cooldownMs,
        speedRatio: config.speedRatio,
        volumeScaling: config.volumeScaling
    )
}

func validateRuntimePackName(_ name: String) throws {
    let normalized = normalizeSourceName(name)
    guard !normalized.isEmpty else {
        throw NSError(domain: "BadApple.Runtime", code: 1, userInfo: [NSLocalizedDescriptionKey: "pack name is required"])
    }
    switch normalized {
    case "sexy", "custom", "chaos", "pain", "halo":
        throw NSError(domain: "BadApple.Runtime", code: 1, userInfo: [NSLocalizedDescriptionKey: "pack name is reserved"])
    default:
        break
    }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_-")
    guard let first = normalized.unicodeScalars.first, CharacterSet.lowercaseLetters.contains(first) else {
        throw NSError(domain: "BadApple.Runtime", code: 1, userInfo: [NSLocalizedDescriptionKey: "pack names must match [a-z][a-z0-9_-]*"])
    }
    for scalar in normalized.unicodeScalars where !allowed.contains(scalar) {
        throw NSError(domain: "BadApple.Runtime", code: 1, userInfo: [NSLocalizedDescriptionKey: "pack names must match [a-z][a-z0-9_-]*"])
    }
}

func validateRuntimeConfig(_ config: RuntimeConfig, validateSelection: (String, String) throws -> Void) throws {
    let normalized = normalizeLegacy(config)
    guard normalized.minAmplitude >= 0, normalized.minAmplitude <= 1 else {
        throw NSError(domain: "BadApple.Runtime", code: 1, userInfo: [NSLocalizedDescriptionKey: "min_amplitude must be between 0.0 and 1.0"])
    }
    guard normalized.cooldownMs > 0 else {
        throw NSError(domain: "BadApple.Runtime", code: 1, userInfo: [NSLocalizedDescriptionKey: "cooldown_ms must be greater than 0"])
    }
    guard normalized.speedRatio > 0 else {
        throw NSError(domain: "BadApple.Runtime", code: 1, userInfo: [NSLocalizedDescriptionKey: "speed_ratio must be greater than 0"])
    }
    try validateSelection(normalized.source, normalized.strategy)
}

func sensitivityLabel(_ value: Double) -> String {
    switch value {
    case sensitivityPresetHigh:
        return "high"
    case sensitivityPresetMedium:
        return "medium"
    case sensitivityPresetLow:
        return "low"
    default:
        return "custom"
    }
}
