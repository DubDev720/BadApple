package audio

import (
	"context"
	"log"
)

type PlayOptions struct {
	Rate   float64
	Volume float64
}

type Player interface {
	Play(ctx context.Context, clipName string, data []byte, opts PlayOptions) error
}

func NewPlayer(workDir string, logger *log.Logger) Player {
	return newPlayer(workDir, logger)
}
