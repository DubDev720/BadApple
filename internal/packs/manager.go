package packs

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"

	"spank/internal/media"
)

type Info struct {
	Name      string
	ClipCount int
	Path      string
}

func Install(packsDir, name, sourceDir string) (Info, error) {
	name = media.NormalizeSourceName(name)
	if err := media.ValidateRuntimePackName(name); err != nil {
		return Info{}, err
	}
	stat, err := os.Stat(sourceDir)
	if err != nil {
		return Info{}, fmt.Errorf("stat source dir: %w", err)
	}
	if !stat.IsDir() {
		return Info{}, fmt.Errorf("source path %q is not a directory", sourceDir)
	}
	if err := os.MkdirAll(packsDir, 0o755); err != nil {
		return Info{}, fmt.Errorf("create packs dir: %w", err)
	}
	targetDir := filepath.Join(packsDir, name)
	if err := os.MkdirAll(targetDir, 0o755); err != nil {
		return Info{}, fmt.Errorf("create target dir: %w", err)
	}
	count, err := NormalizeDirectory(sourceDir, targetDir)
	if err != nil {
		return Info{}, err
	}
	return Info{Name: name, ClipCount: count, Path: targetDir}, nil
}

func List(packsDir string) ([]Info, error) {
	entries, err := os.ReadDir(packsDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("read packs dir: %w", err)
	}
	var infos []Info
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		files, err := filepath.Glob(filepath.Join(packsDir, entry.Name(), "*.wav"))
		if err != nil {
			return nil, fmt.Errorf("glob pack clips: %w", err)
		}
		infos = append(infos, Info{
			Name:      entry.Name(),
			ClipCount: len(files),
			Path:      filepath.Join(packsDir, entry.Name()),
		})
	}
	sort.Slice(infos, func(i, j int) bool { return infos[i].Name < infos[j].Name })
	return infos, nil
}

func Remove(packsDir, name string) error {
	name = media.NormalizeSourceName(name)
	if err := media.ValidateRuntimePackName(name); err != nil {
		return err
	}
	targetDir := filepath.Join(packsDir, name)
	if err := os.RemoveAll(targetDir); err != nil {
		return fmt.Errorf("remove pack: %w", err)
	}
	return nil
}

func NormalizeDirectory(sourceDir, targetDir string) (int, error) {
	files, err := media.CollectSupportedAudioFiles(sourceDir)
	if err != nil {
		return 0, err
	}
	if err := os.MkdirAll(targetDir, 0o755); err != nil {
		return 0, fmt.Errorf("create target dir: %w", err)
	}
	for _, existing := range mustGlob(filepath.Join(targetDir, "*.wav")) {
		if err := os.Remove(existing); err != nil {
			return 0, fmt.Errorf("remove existing clip %s: %w", existing, err)
		}
	}
	if len(files) == 0 {
		return 0, fmt.Errorf("no supported audio files found in %s", sourceDir)
	}
	for i, sourceFile := range files {
		targetFile := filepath.Join(targetDir, fmt.Sprintf("%02d.wav", i))
		if err := media.NormalizeAudioFile(sourceFile, targetFile); err != nil {
			return 0, err
		}
		data, err := os.ReadFile(targetFile)
		if err != nil {
			return 0, fmt.Errorf("read normalized clip %s: %w", targetFile, err)
		}
		if err := media.ValidateClip(media.Clip{Name: filepath.Base(targetFile), Path: targetFile}, data); err != nil {
			return 0, err
		}
	}
	return len(files), nil
}

func mustGlob(pattern string) []string {
	files, err := filepath.Glob(pattern)
	if err != nil {
		return nil
	}
	return files
}
