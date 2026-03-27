package runtime

import (
	"sync"

	"spank/internal/config"
)

type State struct {
	mu     sync.RWMutex
	cfg    config.RuntimeConfig
	paused bool
}

func NewState(cfg config.RuntimeConfig) *State {
	return &State{cfg: cfg}
}

func (s *State) Snapshot() (config.RuntimeConfig, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.cfg, s.paused
}

func (s *State) SetPaused(paused bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.paused = paused
}

func (s *State) ApplyConfig(cfg config.RuntimeConfig) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.cfg = cfg
}
