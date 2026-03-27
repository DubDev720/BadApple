package sensor

import (
	"context"
	"fmt"
	"time"
)

type HelperConfig struct {
	PollInterval time.Duration
	MaxBatch     int
}

func DefaultHelperConfig() HelperConfig {
	return HelperConfig{
		PollInterval: 10 * time.Millisecond,
		MaxBatch:     200,
	}
}

func Run(ctx context.Context, cfg HelperConfig, emit func(SlapEvent) error) error {
	det := NewCandidateDetector()
	sampleCh := make(chan AccelSample, cfg.MaxBatch)
	errCh := make(chan error, 1)
	go func() {
		errCh <- RunAccelerometerStream(ctx, sampleCh)
	}()

	var lastEventTime time.Time
	for {
		select {
		case <-ctx.Done():
			return nil
		case err := <-errCh:
			if err != nil {
				return err
			}
			return nil
		case sample := <-sampleCh:
			tSample := float64(sample.Timestamp.UnixNano()) / 1e9
			ev := det.ProcessSample(sample.X, sample.Y, sample.Z, tSample)
			if ev == nil || ev.Timestamp.Equal(lastEventTime) {
				continue
			}
			lastEventTime = ev.Timestamp
			if err := emit(*ev); err != nil {
				return fmt.Errorf("emit slap event: %w", err)
			}
		case <-time.After(cfg.PollInterval):
		}
	}
}
