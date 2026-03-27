package packs

import (
	"os"
	"path/filepath"
	"testing"
)

func TestInstallListAndRemove(t *testing.T) {
	root := t.TempDir()
	sourceDir := filepath.Join(root, "source")
	packsDir := filepath.Join(root, "packs")
	if err := os.MkdirAll(sourceDir, 0o755); err != nil {
		t.Fatalf("mkdir source: %v", err)
	}
	fixture, err := os.ReadFile(filepath.Join("..", "media", "assets", "sexy", "00.wav"))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	for _, name := range []string{"b.wav", "a.wav"} {
		if err := os.WriteFile(filepath.Join(sourceDir, name), fixture, 0o644); err != nil {
			t.Fatalf("write source file: %v", err)
		}
	}

	info, err := Install(packsDir, "afterglow", sourceDir)
	if err != nil {
		t.Fatalf("install pack: %v", err)
	}
	if info.Name != "afterglow" || info.ClipCount != 2 {
		t.Fatalf("unexpected install info: %+v", info)
	}
	if _, err := os.Stat(filepath.Join(info.Path, "00.wav")); err != nil {
		t.Fatalf("expected renumbered first clip: %v", err)
	}
	if _, err := os.Stat(filepath.Join(info.Path, "01.wav")); err != nil {
		t.Fatalf("expected renumbered second clip: %v", err)
	}

	packInfos, err := List(packsDir)
	if err != nil {
		t.Fatalf("list packs: %v", err)
	}
	if len(packInfos) != 1 || packInfos[0].Name != "afterglow" || packInfos[0].ClipCount != 2 {
		t.Fatalf("unexpected list output: %+v", packInfos)
	}

	if err := Remove(packsDir, "afterglow"); err != nil {
		t.Fatalf("remove pack: %v", err)
	}
	packInfos, err = List(packsDir)
	if err != nil {
		t.Fatalf("list packs after remove: %v", err)
	}
	if len(packInfos) != 0 {
		t.Fatalf("expected no packs after remove, got %+v", packInfos)
	}
}

func TestInstallRejectsReservedName(t *testing.T) {
	root := t.TempDir()
	sourceDir := filepath.Join(root, "source")
	if err := os.MkdirAll(sourceDir, 0o755); err != nil {
		t.Fatalf("mkdir source: %v", err)
	}
	fixture, err := os.ReadFile(filepath.Join("..", "media", "assets", "sexy", "00.wav"))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	if err := os.WriteFile(filepath.Join(sourceDir, "00.wav"), fixture, 0o644); err != nil {
		t.Fatalf("write source file: %v", err)
	}
	if _, err := Install(filepath.Join(root, "packs"), "sexy", sourceDir); err == nil {
		t.Fatal("expected reserved pack name to be rejected")
	}
}
