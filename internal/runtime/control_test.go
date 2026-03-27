package runtime

import (
	"fmt"
	"testing"

	"spank/internal/config"
	"spank/internal/ipc"
)

func TestHandleControlPauseResume(t *testing.T) {
	state := NewState(config.DefaultRuntimeConfig())

	resp := HandleControl(state, ipc.ControlRequest{Command: "pause"}, func() (config.RuntimeConfig, error) {
		return config.DefaultRuntimeConfig(), nil
	}, nil, nil)
	if resp.Status != "ok" || !resp.Paused {
		t.Fatalf("pause response = %+v", resp)
	}

	resp = HandleControl(state, ipc.ControlRequest{Command: "resume"}, func() (config.RuntimeConfig, error) {
		return config.DefaultRuntimeConfig(), nil
	}, nil, nil)
	if resp.Status != "ok" || resp.Paused {
		t.Fatalf("resume response = %+v", resp)
	}
}

func TestHandleControlUpdate(t *testing.T) {
	state := NewState(config.DefaultRuntimeConfig())
	source := "sexy"
	strategy := "escalation"
	cooldown := 500
	resp := HandleControl(state, ipc.ControlRequest{
		Command: "update",
		Update: &ipc.ConfigUpdate{
			Source:     &source,
			Strategy:   &strategy,
			CooldownMs: &cooldown,
		},
	}, func() (config.RuntimeConfig, error) {
		return config.DefaultRuntimeConfig(), nil
	}, nil, nil)
	if resp.Status != "ok" {
		t.Fatalf("update response = %+v", resp)
	}
	if resp.Config == nil || resp.Config.Source != source || resp.Config.Strategy != strategy || resp.Config.CooldownMs != cooldown {
		t.Fatalf("unexpected config after update: %+v", resp.Config)
	}
}

func TestHandleControlUpdatePersists(t *testing.T) {
	state := NewState(config.DefaultRuntimeConfig())
	source := "sexy"
	var saved config.RuntimeConfig
	resp := HandleControl(state, ipc.ControlRequest{
		Command: "update",
		Update:  &ipc.ConfigUpdate{Source: &source},
	}, func() (config.RuntimeConfig, error) {
		return config.DefaultRuntimeConfig(), nil
	}, func(cfg config.RuntimeConfig) error {
		saved = cfg
		return nil
	}, nil)
	if resp.Status != "ok" {
		t.Fatalf("update response = %+v", resp)
	}
	if saved.Source != source {
		t.Fatalf("expected persisted source %q, got %+v", source, saved)
	}
}

func TestHandleControlUpdateRejectsUnknownSource(t *testing.T) {
	state := NewState(config.DefaultRuntimeConfig())
	source := "afterglow"
	resp := HandleControl(state, ipc.ControlRequest{
		Command: "update",
		Update:  &ipc.ConfigUpdate{Source: &source},
	}, func() (config.RuntimeConfig, error) {
		return config.DefaultRuntimeConfig(), nil
	}, nil, func(cfg config.RuntimeConfig) error {
		return fmt.Errorf("source %q has no clips", cfg.Source)
	})
	if resp.Status != "error" {
		t.Fatalf("expected error response, got %+v", resp)
	}
}
