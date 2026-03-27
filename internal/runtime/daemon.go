//go:build embed_media

package runtime

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"math"
	"net"
	"os"
	"path/filepath"
	"sync"
	"time"

	"spank/internal/audio"
	"spank/internal/config"
	"spank/internal/ipc"
	"spank/internal/media"
)

type Daemon struct {
	state           *State
	media           *media.Provider
	player          audio.Player
	configPath      string
	eventSocket     string
	controlSocket   string
	logger          *log.Logger
	playbackMu      sync.Mutex
	lastPlayback    time.Time
	trackerMu       sync.Mutex
	trackers        map[string]*slapTracker
	eventListener   net.Listener
	controlListener net.Listener
}

type slapTracker struct {
	score    float64
	lastTime time.Time
}

func NewDaemon(cfg config.RuntimeConfig, provider *media.Provider, configPath, eventSocket, controlSocket string, logger *log.Logger) *Daemon {
	playbackDir := filepath.Join(filepath.Dir(controlSocket), "playback")
	return NewDaemonWithPlayer(cfg, provider, audio.NewPlayer(playbackDir, logger), configPath, eventSocket, controlSocket, logger)
}

func NewDaemonWithPlayer(cfg config.RuntimeConfig, provider *media.Provider, player audio.Player, configPath, eventSocket, controlSocket string, logger *log.Logger) *Daemon {
	if logger == nil {
		logger = log.New(os.Stderr, "spankd: ", log.LstdFlags)
	}
	if player == nil {
		player = audio.NewPlayer(filepath.Join(filepath.Dir(controlSocket), "playback"), logger)
	}
	return &Daemon{
		state:         NewState(cfg),
		media:         provider,
		player:        player,
		configPath:    configPath,
		eventSocket:   eventSocket,
		controlSocket: controlSocket,
		logger:        logger,
		trackers:      make(map[string]*slapTracker),
	}
}

func (d *Daemon) Run() error {
	eventLn, err := ipc.ListenUnix(d.eventSocket)
	if err != nil {
		return fmt.Errorf("listen event socket: %w", err)
	}
	controlLn, err := ipc.ListenUnix(d.controlSocket)
	if err != nil {
		eventLn.Close()
		return fmt.Errorf("listen control socket: %w", err)
	}
	d.eventListener = eventLn
	d.controlListener = controlLn

	go d.serveEvents()
	go d.serveControl()
	d.logger.Printf("ready event_socket=%s control_socket=%s", d.eventSocket, d.controlSocket)
	return nil
}

func (d *Daemon) Close() error {
	var firstErr error
	if d.eventListener != nil {
		if err := d.eventListener.Close(); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	if d.controlListener != nil {
		if err := d.controlListener.Close(); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}

func (d *Daemon) serveEvents() {
	for {
		conn, err := d.eventListener.Accept()
		if err != nil {
			return
		}
		go func(c net.Conn) {
			var env ipc.EventEnvelope
			if err := json.NewDecoder(c).Decode(&env); err != nil {
				d.logger.Printf("event_decode_error err=%v", err)
				c.Close()
				return
			}
			c.Close()
			if err := validateEventEnvelope(env); err != nil {
				d.logger.Printf("event_rejected err=%v", err)
				return
			}
			switch env.Type {
			case ipc.EventTypeSlap:
				if err := d.handleSlap(*env.Slap); err != nil {
					d.logger.Printf("event_handle_error err=%v", err)
				}
			case ipc.EventTypeHealth:
				d.logger.Printf("helper_health msg=%q", env.Health.Message)
			case ipc.EventTypeError:
				d.logger.Printf("helper_error msg=%q", env.HelperErr.Message)
			}
		}(conn)
	}
}

func (d *Daemon) serveControl() {
	for {
		conn, err := d.controlListener.Accept()
		if err != nil {
			return
		}
		go func(c net.Conn) {
			var req ipc.ControlRequest
			if err := json.NewDecoder(c).Decode(&req); err != nil {
				_ = json.NewEncoder(c).Encode(ipc.ControlResponse{Status: "error", Error: err.Error()})
				c.Close()
				return
			}
			resp := HandleControl(d.state, req, d.reloadConfig, d.persistConfig, d.validateConfig)
			_ = json.NewEncoder(c).Encode(resp)
			c.Close()
		}(conn)
	}
}

func (d *Daemon) reloadConfig() (config.RuntimeConfig, error) {
	cfg, err := config.Load(d.configPath)
	if err != nil {
		return config.RuntimeConfig{}, err
	}
	if err := d.validateConfig(cfg); err != nil {
		return config.RuntimeConfig{}, err
	}
	return cfg, nil
}

func (d *Daemon) persistConfig(cfg config.RuntimeConfig) error {
	return config.Save(d.configPath, cfg)
}

func (d *Daemon) validateConfig(cfg config.RuntimeConfig) error {
	return d.media.ValidateSelection(media.Source(cfg.Source), media.Strategy(cfg.Strategy))
}

func (d *Daemon) handleSlap(event ipc.SlapEvent) error {
	cfg, paused := d.state.Snapshot()
	if paused {
		return nil
	}
	if event.Amplitude < cfg.MinAmplitude {
		return nil
	}

	d.playbackMu.Lock()
	defer d.playbackMu.Unlock()
	cooldown := time.Duration(cfg.CooldownMs) * time.Millisecond
	if time.Since(d.lastPlayback) <= cooldown {
		return nil
	}

	source := media.Source(cfg.Source)
	strategy := media.Strategy(cfg.Strategy)

	var clip media.Clip
	var err error
	switch strategy {
	case media.StrategyRandom:
		clip, err = d.media.RandomClip(source)
	case media.StrategyEscalation:
		score := d.recordScore(cfg.Source, event.Timestamp)
		clip, err = d.media.EscalationClip(source, score, cooldown)
	default:
		return fmt.Errorf("unsupported strategy %q", cfg.Strategy)
	}
	if err != nil {
		return err
	}

	data, err := d.media.Read(clip)
	if err != nil {
		return err
	}
	if err := d.player.Play(context.Background(), clip.Name, data, audio.PlayOptions{
		Rate:   cfg.SpeedRatio,
		Volume: playbackVolume(event.Amplitude, cfg.VolumeScaling),
	}); err != nil {
		return err
	}
	d.lastPlayback = time.Now()
	d.logger.Printf("played source=%s strategy=%s clip=%s amplitude=%.4f severity=%s", cfg.Source, cfg.Strategy, clip.Name, event.Amplitude, event.Severity)
	return nil
}

func (d *Daemon) recordScore(source string, now time.Time) float64 {
	const halfLife = 30.0
	d.trackerMu.Lock()
	defer d.trackerMu.Unlock()
	tracker := d.trackers[source]
	if tracker == nil {
		tracker = &slapTracker{}
		d.trackers[source] = tracker
	}
	if !tracker.lastTime.IsZero() {
		elapsed := now.Sub(tracker.lastTime).Seconds()
		tracker.score *= math.Pow(0.5, elapsed/halfLife)
	}
	tracker.score += 1.0
	tracker.lastTime = now
	return tracker.score
}

func validateEventEnvelope(env ipc.EventEnvelope) error {
	switch env.Type {
	case ipc.EventTypeSlap:
		if env.Slap == nil {
			return fmt.Errorf("slap event missing payload")
		}
		if env.Health != nil || env.HelperErr != nil {
			return fmt.Errorf("slap event contains extra payloads")
		}
		return validateSlapEvent(*env.Slap)
	case ipc.EventTypeHealth:
		if env.Health == nil {
			return fmt.Errorf("health event missing payload")
		}
		if env.Slap != nil || env.HelperErr != nil {
			return fmt.Errorf("health event contains extra payloads")
		}
		if env.Health.Message == "" {
			return fmt.Errorf("health event missing message")
		}
		if env.Health.Timestamp.IsZero() {
			return fmt.Errorf("health event missing timestamp")
		}
		return nil
	case ipc.EventTypeError:
		if env.HelperErr == nil {
			return fmt.Errorf("error event missing payload")
		}
		if env.Slap != nil || env.Health != nil {
			return fmt.Errorf("error event contains extra payloads")
		}
		if env.HelperErr.Message == "" {
			return fmt.Errorf("error event missing message")
		}
		if env.HelperErr.Timestamp.IsZero() {
			return fmt.Errorf("error event missing timestamp")
		}
		return nil
	default:
		return fmt.Errorf("unsupported event type %q", env.Type)
	}
}

func validateSlapEvent(event ipc.SlapEvent) error {
	if event.Timestamp.IsZero() {
		return fmt.Errorf("slap event missing timestamp")
	}
	if event.Amplitude < 0 || event.Amplitude > 1 {
		return fmt.Errorf("slap amplitude %.4f out of range", event.Amplitude)
	}
	return nil
}

func playbackVolume(amplitude float64, scaled bool) float64 {
	if !scaled {
		return 1.0
	}
	if amplitude <= 0 {
		return 0.35
	}
	if amplitude >= 1 {
		return 1.0
	}
	return 0.35 + amplitude*0.65
}
