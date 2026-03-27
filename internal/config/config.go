package config

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

const (
	DefaultMinAmplitude = 0.28
	DefaultCooldownMs   = 750
	DefaultSpeedRatio   = 1.0
	DefaultSource       = "sexy"
	DefaultStrategy     = "random"
)

type RuntimeConfig struct {
	Source        string  `json:"source"`
	Strategy      string  `json:"strategy"`
	MinAmplitude  float64 `json:"min_amplitude"`
	CooldownMs    int     `json:"cooldown_ms"`
	SpeedRatio    float64 `json:"speed_ratio"`
	VolumeScaling bool    `json:"volume_scaling"`
}

func DefaultRuntimeConfig() RuntimeConfig {
	return RuntimeConfig{
		Source:        DefaultSource,
		Strategy:      DefaultStrategy,
		MinAmplitude:  DefaultMinAmplitude,
		CooldownMs:    DefaultCooldownMs,
		SpeedRatio:    DefaultSpeedRatio,
		VolumeScaling: false,
	}
}

func Load(path string) (RuntimeConfig, error) {
	cfg := DefaultRuntimeConfig()
	if path == "" {
		return cfg, nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return cfg, err
	}
	if err := json.Unmarshal(data, &cfg); err != nil {
		return cfg, fmt.Errorf("decode config: %w", err)
	}
	cfg = NormalizeLegacy(cfg)
	if err := Validate(cfg); err != nil {
		return cfg, err
	}
	return cfg, nil
}

func Save(path string, cfg RuntimeConfig) error {
	if path == "" {
		return nil
	}
	if err := Validate(cfg); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create config dir: %w", err)
	}
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return fmt.Errorf("encode config: %w", err)
	}
	data = append(data, '\n')
	if err := os.WriteFile(path, data, 0o644); err != nil {
		return fmt.Errorf("write config: %w", err)
	}
	return nil
}

func Validate(cfg RuntimeConfig) error {
	if cfg.Source == "" {
		return fmt.Errorf("source is required")
	}

	switch cfg.Strategy {
	case "random", "escalation":
	default:
		return fmt.Errorf("unsupported strategy %q", cfg.Strategy)
	}

	if cfg.Source == "chaos" && cfg.Strategy != "random" {
		return fmt.Errorf("source %q only supports strategy %q", cfg.Source, "random")
	}
	if cfg.MinAmplitude < 0 || cfg.MinAmplitude > 1 {
		return fmt.Errorf("min_amplitude must be between 0.0 and 1.0")
	}
	if cfg.CooldownMs <= 0 {
		return fmt.Errorf("cooldown_ms must be greater than 0")
	}
	if cfg.SpeedRatio <= 0 {
		return fmt.Errorf("speed_ratio must be greater than 0")
	}
	return nil
}

func NormalizeLegacy(cfg RuntimeConfig) RuntimeConfig {
	switch cfg.Source {
	case "pain":
		cfg.Source = DefaultSource
		if cfg.Strategy == "" {
			cfg.Strategy = DefaultStrategy
		}
	case "halo":
		cfg.Source = DefaultSource
		cfg.Strategy = DefaultStrategy
	}
	if cfg.Source == "" {
		cfg.Source = DefaultSource
	}
	if cfg.Strategy == "" {
		cfg.Strategy = DefaultStrategy
	}
	return cfg
}
