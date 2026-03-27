package runtime

import (
	"fmt"

	"spank/internal/config"
	"spank/internal/ipc"
)

func HandleControl(state *State, req ipc.ControlRequest, reload func() (config.RuntimeConfig, error), persist func(config.RuntimeConfig) error, validate func(config.RuntimeConfig) error) ipc.ControlResponse {
	switch req.Command {
	case "pause":
		state.SetPaused(true)
	case "resume":
		state.SetPaused(false)
	case "reload":
		cfg, err := reload()
		if err != nil {
			cur, paused := state.Snapshot()
			return ipc.ControlResponse{Status: "error", Error: err.Error(), Config: &cur, Paused: paused}
		}
		state.ApplyConfig(cfg)
	case "update":
		cur, paused := state.Snapshot()
		next := ApplyUpdate(cur, req.Update)
		if err := config.Validate(next); err != nil {
			return ipc.ControlResponse{Status: "error", Error: err.Error(), Config: &cur, Paused: paused}
		}
		if validate != nil {
			if err := validate(next); err != nil {
				return ipc.ControlResponse{Status: "error", Error: err.Error(), Config: &cur, Paused: paused}
			}
		}
		state.ApplyConfig(next)
		if persist != nil {
			if err := persist(next); err != nil {
				return ipc.ControlResponse{Status: "error", Error: err.Error(), Config: &cur, Paused: paused}
			}
		}
	case "status":
	default:
		cur, paused := state.Snapshot()
		return ipc.ControlResponse{Status: "error", Error: fmt.Sprintf("unknown command %q", req.Command), Config: &cur, Paused: paused}
	}

	cur, paused := state.Snapshot()
	return ipc.ControlResponse{Status: "ok", Config: &cur, Paused: paused}
}
