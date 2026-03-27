package main

import (
	"context"
	"flag"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"spank/internal/ipc"
	"spank/internal/paths"
	helpersensor "spank/internal/sensor"
)

func main() {
	var runtimeDir string

	flag.StringVar(&runtimeDir, "runtime-dir", paths.DefaultRuntimeDir(), "Runtime directory for daemon sockets")
	flag.Parse()

	logger := log.New(os.Stderr, "spank-sensor-helper: ", log.LstdFlags)
	eventSocket := filepath.Join(runtimeDir, "spankd.sock")

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	cfg := helpersensor.DefaultHelperConfig()
	err := helpersensor.Run(ctx, cfg, func(event helpersensor.SlapEvent) error {
		env := ipc.EventEnvelope{
			Type: ipc.EventTypeSlap,
			Slap: &ipc.SlapEvent{
				Amplitude: event.Amplitude,
				Severity:  event.Severity,
				Timestamp: event.Timestamp,
			},
		}
		if err := ipc.Send(eventSocket, env); err != nil {
			logger.Printf("event_send_error err=%v", err)
			time.Sleep(500 * time.Millisecond)
		}
		return nil
	})
	if err != nil {
		logger.Fatalf("helper failed: %v", err)
	}
}
