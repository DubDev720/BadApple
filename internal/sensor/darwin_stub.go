//go:build !darwin

package sensor

import (
	"context"
	"fmt"
	"time"
)

type AccelSample struct {
	X, Y, Z   float64
	Timestamp time.Time
}

func RunAccelerometerStream(ctx context.Context, out chan<- AccelSample) error {
	_ = ctx
	_ = out
	return fmt.Errorf("accelerometer streaming is unsupported on this platform")
}
