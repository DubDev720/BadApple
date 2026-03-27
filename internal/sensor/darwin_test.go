//go:build darwin

package sensor

import (
	"context"
	"encoding/binary"
	"os"
	"testing"
	"time"
)

func TestParseIMUReport(t *testing.T) {
	payload := make([]byte, IMUDataOffset+12)
	binary.LittleEndian.PutUint32(payload[IMUDataOffset:], uint32(123456))
	binary.LittleEndian.PutUint32(payload[IMUDataOffset+4:], uint32(0xffff0001))
	binary.LittleEndian.PutUint32(payload[IMUDataOffset+8:], uint32(77))

	x, y, z := parseIMUReport(payload)
	if x != 123456 || y != -65535 || z != 77 {
		t.Fatalf("unexpected parsed report: x=%d y=%d z=%d", x, y, z)
	}
}

func TestCandidateDetectorEmitsEventOnSpike(t *testing.T) {
	det := NewCandidateDetector()
	tNow := float64(time.Now().UnixNano()) / 1e9

	for i := 0; i < 300; i++ {
		ev := det.ProcessSample(0, 0, 0, tNow+float64(i)/float64(det.SampleRate()))
		if ev != nil {
			t.Fatalf("unexpected event during baseline at sample %d: %+v", i, ev)
		}
	}

	var got *SlapEvent
	for i := 0; i < 40; i++ {
		got = det.ProcessSample(0.8, 0.8, 0.8, tNow+float64(300+i)/float64(det.SampleRate()))
		if got != nil {
			break
		}
	}
	if got == nil {
		t.Fatal("expected detector to emit an event for sustained spike")
	}
	if got.Amplitude <= 0 {
		t.Fatalf("expected positive amplitude, got %+v", got)
	}
	if got.Timestamp.IsZero() {
		t.Fatalf("expected event timestamp, got %+v", got)
	}
}

func TestHardwareAccelerometerStream(t *testing.T) {
	if os.Getenv("SPANK_HARDWARE_TEST") != "1" {
		t.Skip("set SPANK_HARDWARE_TEST=1 to run hardware accelerometer validation")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	samples := make(chan AccelSample, 64)
	errCh := make(chan error, 1)
	go func() {
		errCh <- RunAccelerometerStream(ctx, samples)
	}()

	count := 0
	timeout := time.After(2 * time.Second)
	for count < 5 {
		select {
		case sample := <-samples:
			count++
			if sample.Timestamp.IsZero() {
				t.Fatal("received sample without timestamp")
			}
		case err := <-errCh:
			if err != nil && err != context.DeadlineExceeded && err != context.Canceled {
				t.Fatalf("hardware stream failed: %v", err)
			}
			if count == 0 {
				t.Fatalf("hardware stream exited before yielding samples")
			}
			return
		case <-timeout:
			t.Fatalf("timed out waiting for accelerometer samples; received %d", count)
		}
	}

	cancel()
	select {
	case err := <-errCh:
		if err != nil && err != context.DeadlineExceeded && err != context.Canceled {
			t.Fatalf("stream shutdown failed: %v", err)
		}
	case <-time.After(1 * time.Second):
		t.Fatal("timed out waiting for stream shutdown")
	}
}

func TestHardwareHelperRunPath(t *testing.T) {
	if os.Getenv("SPANK_HARDWARE_TEST") != "1" {
		t.Skip("set SPANK_HARDWARE_TEST=1 to run hardware helper validation")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()

	if err := Run(ctx, DefaultHelperConfig(), func(SlapEvent) error { return nil }); err != nil {
		t.Fatalf("helper run path failed: %v", err)
	}
}
