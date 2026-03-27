//go:build embed_media

package main

import (
	"context"
	"flag"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	"spank/internal/config"
	"spank/internal/media"
	"spank/internal/paths"
	"spank/internal/runtime"
)

func main() {
	var runtimeDir string
	var configPath string

	flag.StringVar(&runtimeDir, "runtime-dir", paths.DefaultRuntimeDir(), "Runtime directory for sockets")
	flag.StringVar(&configPath, "config", paths.DefaultConfigPath(), "Path to runtime config")
	flag.Parse()

	logger := log.New(os.Stderr, "spankd: ", log.LstdFlags)

	cfg := config.DefaultRuntimeConfig()
	if loaded, err := config.Load(configPath); err == nil {
		cfg = loaded
	} else if !os.IsNotExist(err) {
		logger.Fatalf("load config: %v", err)
	}

	provider, err := media.NewProvider()
	if err != nil {
		logger.Fatalf("init media: %v", err)
	}
	if err := provider.ValidateSelection(media.Source(cfg.Source), media.Strategy(cfg.Strategy)); err != nil {
		logger.Fatalf("validate config: %v", err)
	}

	eventSocket := filepath.Join(runtimeDir, "spankd.sock")
	controlSocket := filepath.Join(runtimeDir, "spankctl.sock")
	daemon := runtime.NewDaemon(cfg, provider, configPath, eventSocket, controlSocket, logger)
	if err := daemon.Run(); err != nil {
		logger.Fatalf("run daemon: %v", err)
	}
	defer daemon.Close()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)
	defer stop()
	<-ctx.Done()
}
