//go:build embed_media

package runtime

import (
	"context"
	"encoding/json"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"spank/internal/audio"
	"spank/internal/config"
	"spank/internal/ipc"
	"spank/internal/media"
)

type recordedPlay struct {
	clipName string
	opts     audio.PlayOptions
}

type recordingPlayer struct {
	mu    sync.Mutex
	calls []recordedPlay
	ch    chan recordedPlay
}

func newRecordingPlayer() *recordingPlayer {
	return &recordingPlayer{
		ch: make(chan recordedPlay, 8),
	}
}

func (p *recordingPlayer) Play(ctx context.Context, clipName string, data []byte, opts audio.PlayOptions) error {
	call := recordedPlay{clipName: clipName, opts: opts}
	p.mu.Lock()
	p.calls = append(p.calls, call)
	p.mu.Unlock()
	p.ch <- call
	return nil
}

func (p *recordingPlayer) callCount() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.calls)
}

func TestDaemonControlSocketRoundTrip(t *testing.T) {
	_, _, controlSocket, _, cleanup := newTestDaemon(t, config.DefaultRuntimeConfig())
	defer cleanup()

	var status ipc.ControlResponse
	if err := ipc.Request(controlSocket, ipc.ControlRequest{Command: "status"}, &status); err != nil {
		t.Fatalf("status request: %v", err)
	}
	if status.Status != "ok" || status.Config == nil {
		t.Fatalf("unexpected status response: %+v", status)
	}

	source := "sexy"
	strategy := "escalation"
	cooldown := 600
	var updated ipc.ControlResponse
	if err := ipc.Request(controlSocket, ipc.ControlRequest{
		Command: "update",
		Update: &ipc.ConfigUpdate{
			Source:     &source,
			Strategy:   &strategy,
			CooldownMs: &cooldown,
		},
	}, &updated); err != nil {
		t.Fatalf("update request: %v", err)
	}
	if updated.Status != "ok" || updated.Config == nil {
		t.Fatalf("unexpected update response: %+v", updated)
	}
	if updated.Config.Source != source || updated.Config.Strategy != strategy || updated.Config.CooldownMs != cooldown {
		t.Fatalf("update response did not apply config: %+v", updated.Config)
	}
}

func TestDaemonControlSocketRejectsMalformedJSON(t *testing.T) {
	_, _, controlSocket, _, cleanup := newTestDaemon(t, config.DefaultRuntimeConfig())
	defer cleanup()

	conn, err := net.Dial("unix", controlSocket)
	if err != nil {
		t.Fatalf("dial control socket: %v", err)
	}
	defer conn.Close()

	if _, err := io.WriteString(conn, "{not-json}\n"); err != nil {
		t.Fatalf("write malformed payload: %v", err)
	}

	var resp ipc.ControlResponse
	if err := json.NewDecoder(conn).Decode(&resp); err != nil {
		t.Fatalf("decode malformed-json response: %v", err)
	}
	if resp.Status != "error" || resp.Error == "" {
		t.Fatalf("unexpected malformed-json response: %+v", resp)
	}
}

func TestDaemonEventSocketPlaysValidSlap(t *testing.T) {
	_, player, _, eventSocket, cleanup := newTestDaemon(t, config.DefaultRuntimeConfig())
	defer cleanup()

	err := ipc.Send(eventSocket, ipc.EventEnvelope{
		Type: ipc.EventTypeSlap,
		Slap: &ipc.SlapEvent{
			Amplitude: 0.9,
			Severity:  "high",
			Timestamp: time.Now(),
		},
	})
	if err != nil {
		t.Fatalf("send slap event: %v", err)
	}

	select {
	case call := <-player.ch:
		if call.clipName == "" {
			t.Fatalf("playback call missing clip name: %+v", call)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for playback")
	}
}

func TestDaemonEventSocketRejectsUnknownType(t *testing.T) {
	_, player, _, eventSocket, cleanup := newTestDaemon(t, config.DefaultRuntimeConfig())
	defer cleanup()

	err := ipc.Send(eventSocket, ipc.EventEnvelope{
		Type: "mystery",
		Slap: &ipc.SlapEvent{
			Amplitude: 0.9,
			Timestamp: time.Now(),
		},
	})
	if err != nil {
		t.Fatalf("send unknown event: %v", err)
	}

	select {
	case call := <-player.ch:
		t.Fatalf("unexpected playback for unknown event: %+v", call)
	case <-time.After(250 * time.Millisecond):
	}

	if player.callCount() != 0 {
		t.Fatalf("unexpected playback count for unknown event: %d", player.callCount())
	}
}

func newTestDaemon(t *testing.T, cfg config.RuntimeConfig) (*Daemon, *recordingPlayer, string, string, func()) {
	t.Helper()

	runtimeDir, err := os.MkdirTemp("/tmp", "spank-test-")
	if err != nil {
		t.Fatalf("create temp runtime dir: %v", err)
	}
	configPath := filepath.Join(runtimeDir, "config.json")
	eventSocket := filepath.Join(runtimeDir, "spankd.sock")
	controlSocket := filepath.Join(runtimeDir, "spankctl.sock")

	provider, err := media.NewProvider()
	if err != nil {
		t.Fatalf("new media provider: %v", err)
	}

	player := newRecordingPlayer()
	daemon := NewDaemonWithPlayer(
		cfg,
		provider,
		player,
		configPath,
		eventSocket,
		controlSocket,
		log.New(io.Discard, "", 0),
	)
	if err := daemon.Run(); err != nil {
		t.Fatalf("run daemon: %v", err)
	}

	cleanup := func() {
		if err := daemon.Close(); err != nil {
			t.Fatalf("close daemon: %v", err)
		}
		if err := os.RemoveAll(runtimeDir); err != nil {
			t.Fatalf("remove temp runtime dir: %v", err)
		}
	}
	return daemon, player, controlSocket, eventSocket, cleanup
}
