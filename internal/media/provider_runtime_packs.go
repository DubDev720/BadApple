//go:build embed_media && runtime_media_packs

package media

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"

	"spank/internal/paths"
)

func loadOptionalRuntimePacks(p *Provider) error {
	packsDir := paths.DefaultPacksDir()
	entries, err := os.ReadDir(packsDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("read runtime packs dir: %w", err)
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Name() < entries[j].Name() })
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		name := NormalizeSourceName(entry.Name())
		if err := ValidateRuntimePackName(name); err != nil {
			return fmt.Errorf("invalid runtime pack %q: %w", entry.Name(), err)
		}
		dir := filepath.Join(packsDir, entry.Name())
		fsys := os.DirFS(packsDir)
		if err := ensurePackHasWAVs(fsys, entry.Name()); err != nil {
			return fmt.Errorf("runtime pack %q: %w", entry.Name(), err)
		}
		if err := p.loadFromFS(fsys, Source(name), entry.Name()); err != nil {
			return fmt.Errorf("load runtime pack %q from %s: %w", entry.Name(), dir, err)
		}
	}
	return nil
}

func ensurePackHasWAVs(fsys fs.FS, dir string) error {
	entries, err := fs.ReadDir(fsys, dir)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if !entry.IsDir() && filepath.Ext(entry.Name()) == ".wav" {
			return nil
		}
	}
	return fmt.Errorf("no wav files found")
}
