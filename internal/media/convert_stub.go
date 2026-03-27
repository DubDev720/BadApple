//go:build !darwin

package media

import (
	"fmt"
	"path/filepath"
	"strings"
)

func SupportedImportExtensions() []string {
	return []string{".wav"}
}

func IsSupportedImportFile(name string) bool {
	return strings.ToLower(filepath.Ext(name)) == ".wav"
}

func CollectSupportedAudioFiles(string) ([]string, error) {
	return nil, fmt.Errorf("audio import is only supported on darwin")
}

func NormalizeAudioFile(_, _ string) error {
	return fmt.Errorf("audio conversion is only supported on darwin")
}
