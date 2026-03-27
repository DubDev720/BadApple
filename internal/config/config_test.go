package config

import "testing"

func TestDefaultRuntimeConfigValid(t *testing.T) {
	cfg := DefaultRuntimeConfig()
	if err := Validate(cfg); err != nil {
		t.Fatalf("default config should validate: %v", err)
	}
}

func TestValidateRejectsUnsupportedCombination(t *testing.T) {
	cfg := DefaultRuntimeConfig()
	cfg.Source = "chaos"
	cfg.Strategy = "escalation"
	if err := Validate(cfg); err == nil {
		t.Fatal("expected chaos+escalation to be rejected")
	}
}

func TestValidateAllowsRuntimePackSource(t *testing.T) {
	cfg := DefaultRuntimeConfig()
	cfg.Source = "afterglow"
	cfg.Strategy = "escalation"
	if err := Validate(cfg); err != nil {
		t.Fatalf("expected runtime pack source to validate, got %v", err)
	}
}

func TestNormalizeLegacyMapsRemovedSources(t *testing.T) {
	cfg := RuntimeConfig{Source: "pain", Strategy: "escalation", MinAmplitude: DefaultMinAmplitude, CooldownMs: DefaultCooldownMs, SpeedRatio: DefaultSpeedRatio}
	cfg = NormalizeLegacy(cfg)
	if cfg.Source != DefaultSource || cfg.Strategy != "escalation" {
		t.Fatalf("unexpected normalized pain config: %+v", cfg)
	}
	cfg = RuntimeConfig{Source: "halo", Strategy: "random", MinAmplitude: DefaultMinAmplitude, CooldownMs: DefaultCooldownMs, SpeedRatio: DefaultSpeedRatio}
	cfg = NormalizeLegacy(cfg)
	if cfg.Source != DefaultSource || cfg.Strategy != DefaultStrategy {
		t.Fatalf("unexpected normalized halo config: %+v", cfg)
	}
}

func TestSaveAndLoadRoundTrip(t *testing.T) {
	dir := t.TempDir()
	path := dir + "/config.json"
	cfg := DefaultRuntimeConfig()
	cfg.Source = "custom"
	cfg.Strategy = "escalation"
	if err := Save(path, cfg); err != nil {
		t.Fatalf("save config: %v", err)
	}
	loaded, err := Load(path)
	if err != nil {
		t.Fatalf("load config: %v", err)
	}
	if loaded.Source != cfg.Source || loaded.Strategy != cfg.Strategy || loaded.MinAmplitude != cfg.MinAmplitude {
		t.Fatalf("unexpected round trip config: %+v", loaded)
	}
}
