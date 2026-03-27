package cli

import "testing"

func TestParseModeCommand(t *testing.T) {
	cmd, err := Parse([]string{"mode", "sexy", "escalation"})
	if err != nil {
		t.Fatalf("parse mode: %v", err)
	}
	if cmd.Request == nil || cmd.Request.Command != "update" {
		t.Fatalf("unexpected request: %+v", cmd.Request)
	}
	if cmd.Request.Update == nil || cmd.Request.Update.Source == nil || *cmd.Request.Update.Source != "sexy" {
		t.Fatalf("unexpected mode source: %+v", cmd.Request.Update)
	}
	if cmd.Request.Update.Strategy == nil || *cmd.Request.Update.Strategy != "escalation" {
		t.Fatalf("unexpected mode strategy: %+v", cmd.Request.Update)
	}
}

func TestParseSensitivityPreset(t *testing.T) {
	cmd, err := Parse([]string{"sensitivity", "high"})
	if err != nil {
		t.Fatalf("parse sensitivity: %v", err)
	}
	if cmd.Request == nil || cmd.Request.Update == nil || cmd.Request.Update.MinAmplitude == nil {
		t.Fatalf("unexpected request: %+v", cmd.Request)
	}
	if got := *cmd.Request.Update.MinAmplitude; got != 0.23 {
		t.Fatalf("expected high sensitivity amplitude 0.23, got %v", got)
	}
}

func TestParseLegacyFlags(t *testing.T) {
	cmd, err := Parse([]string{"-command", "update", "-source", "sexy", "-strategy", "random", "-cooldown", "500"})
	if err != nil {
		t.Fatalf("parse legacy flags: %v", err)
	}
	if !cmd.JSON {
		t.Fatal("expected legacy mode to default to json output")
	}
	if cmd.Request == nil || cmd.Request.Update == nil {
		t.Fatalf("unexpected request: %+v", cmd.Request)
	}
	if cmd.Request.Update.Source == nil || *cmd.Request.Update.Source != "sexy" {
		t.Fatalf("unexpected source: %+v", cmd.Request.Update)
	}
	if cmd.Request.Update.CooldownMs == nil || *cmd.Request.Update.CooldownMs != 500 {
		t.Fatalf("unexpected cooldown: %+v", cmd.Request.Update)
	}
}

func TestParsePackInstall(t *testing.T) {
	cmd, err := Parse([]string{"pack", "install", "afterglow", "/tmp/afterglow"})
	if err != nil {
		t.Fatalf("parse pack install: %v", err)
	}
	if cmd.Name != CommandPack || cmd.PackAction != "install" || cmd.PackName != "afterglow" || cmd.PackSourceDir != "/tmp/afterglow" {
		t.Fatalf("unexpected pack command: %+v", cmd)
	}
}

func TestParseSetRequiresChange(t *testing.T) {
	if _, err := Parse([]string{"set"}); err == nil {
		t.Fatal("expected parse error when set has no flags")
	}
}

func TestParseHelpCommand(t *testing.T) {
	cmd, err := Parse([]string{"help"})
	if err != nil {
		t.Fatalf("parse help: %v", err)
	}
	if cmd.Name != CommandHelp {
		t.Fatalf("expected help command, got %+v", cmd)
	}
}

func TestParseHelpFlag(t *testing.T) {
	cmd, err := Parse([]string{"--help"})
	if err != nil {
		t.Fatalf("parse --help: %v", err)
	}
	if cmd.Name != CommandHelp {
		t.Fatalf("expected help command, got %+v", cmd)
	}
}
