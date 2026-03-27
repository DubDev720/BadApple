//go:build darwin

package media

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

var supportedImportExtensions = []string{".wav", ".mp3", ".m4a", ".aac", ".aif", ".aiff", ".caf"}

func SupportedImportExtensions() []string {
	out := make([]string, len(supportedImportExtensions))
	copy(out, supportedImportExtensions)
	return out
}

func IsSupportedImportFile(name string) bool {
	ext := strings.ToLower(filepath.Ext(name))
	for _, candidate := range supportedImportExtensions {
		if ext == candidate {
			return true
		}
	}
	return false
}

func CollectSupportedAudioFiles(dir string) ([]string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("read source dir: %w", err)
	}
	var files []string
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		if !IsSupportedImportFile(entry.Name()) {
			continue
		}
		files = append(files, filepath.Join(dir, entry.Name()))
	}
	sort.Strings(files)
	return files, nil
}

func NormalizeAudioFile(src, dst string) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return fmt.Errorf("create destination dir: %w", err)
	}
	if err := os.RemoveAll(dst); err != nil {
		return fmt.Errorf("remove existing destination: %w", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	cmd := exec.CommandContext(
		ctx,
		"/usr/bin/afconvert",
		"-f", "WAVE",
		"-d", fmt.Sprintf("LEI16@%d", CanonicalSampleRate),
		"-c", fmt.Sprintf("%d", CanonicalChannels),
		src,
		dst,
	)
	output, err := cmd.CombinedOutput()
	if ctx.Err() == context.DeadlineExceeded {
		return fmt.Errorf("convert %s: timed out", src)
	}
	if err != nil {
		msg := strings.TrimSpace(string(output))
		if msg == "" {
			msg = err.Error()
		}
		return fmt.Errorf("convert %s: %s", src, msg)
	}
	return nil
}
