package ipc

import (
	"time"

	"spank/internal/config"
)

const (
	EventTypeSlap   = "slap"
	EventTypeHealth = "health"
	EventTypeError  = "error"
)

type EventEnvelope struct {
	Type      string       `json:"type"`
	Slap      *SlapEvent   `json:"slap,omitempty"`
	Health    *HealthEvent `json:"health,omitempty"`
	HelperErr *ErrorEvent  `json:"helper_error,omitempty"`
}

type SlapEvent struct {
	Amplitude float64   `json:"amplitude"`
	Severity  string    `json:"severity,omitempty"`
	Timestamp time.Time `json:"timestamp"`
}

type HealthEvent struct {
	Message   string    `json:"message"`
	Timestamp time.Time `json:"timestamp"`
}

type ErrorEvent struct {
	Message   string    `json:"message"`
	Timestamp time.Time `json:"timestamp"`
}

type ControlRequest struct {
	Command string        `json:"command"`
	Update  *ConfigUpdate `json:"update,omitempty"`
}

type ConfigUpdate struct {
	Source        *string  `json:"source,omitempty"`
	Strategy      *string  `json:"strategy,omitempty"`
	MinAmplitude  *float64 `json:"min_amplitude,omitempty"`
	CooldownMs    *int     `json:"cooldown_ms,omitempty"`
	SpeedRatio    *float64 `json:"speed_ratio,omitempty"`
	VolumeScaling *bool    `json:"volume_scaling,omitempty"`
}

type ControlResponse struct {
	Status string                `json:"status"`
	Error  string                `json:"error,omitempty"`
	Config *config.RuntimeConfig `json:"config,omitempty"`
	Paused bool                  `json:"paused"`
}
