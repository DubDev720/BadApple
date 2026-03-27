//go:build !darwin

package audio

import (
	"context"
	"fmt"
	"log"
)

type unsupportedPlayer struct{}

func newPlayer(workDir string, logger *log.Logger) Player {
	_ = workDir
	_ = logger
	return unsupportedPlayer{}
}

func (unsupportedPlayer) Play(ctx context.Context, clipName string, data []byte, opts PlayOptions) error {
	return fmt.Errorf("audio playback is unsupported on this platform")
}
