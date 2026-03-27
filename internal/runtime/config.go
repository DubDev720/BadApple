package runtime

import (
	"spank/internal/config"
	"spank/internal/ipc"
)

func ApplyUpdate(cfg config.RuntimeConfig, update *ipc.ConfigUpdate) config.RuntimeConfig {
	if update == nil {
		return cfg
	}
	if update.Source != nil {
		cfg.Source = *update.Source
	}
	if update.Strategy != nil {
		cfg.Strategy = *update.Strategy
	}
	if update.MinAmplitude != nil {
		cfg.MinAmplitude = *update.MinAmplitude
	}
	if update.CooldownMs != nil {
		cfg.CooldownMs = *update.CooldownMs
	}
	if update.SpeedRatio != nil {
		cfg.SpeedRatio = *update.SpeedRatio
	}
	if update.VolumeScaling != nil {
		cfg.VolumeScaling = *update.VolumeScaling
	}
	return cfg
}
