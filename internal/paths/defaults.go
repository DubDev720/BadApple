package paths

import (
	"os"
	"path/filepath"
)

func homeDir() string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return "."
	}
	return home
}

func DefaultAppSupportDir() string {
	return filepath.Join(homeDir(), "Library", "Application Support", "spank")
}

func DefaultRuntimeDir() string {
	return filepath.Join(DefaultAppSupportDir(), "run")
}

func DefaultConfigPath() string {
	return filepath.Join(DefaultAppSupportDir(), "config.json")
}

func DefaultLogDir() string {
	return filepath.Join(homeDir(), "Library", "Logs", "spank")
}

func DefaultBinDir() string {
	return filepath.Join(DefaultAppSupportDir(), "bin")
}

func DefaultPacksDir() string {
	return filepath.Join(DefaultAppSupportDir(), "packs")
}

func DefaultLaunchAgentsDir() string {
	return filepath.Join(homeDir(), "Library", "LaunchAgents")
}
