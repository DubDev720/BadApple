package cli

import "spank/internal/ipc"

const (
	CommandHelp        = "help"
	CommandStatus      = "status"
	CommandPause       = "pause"
	CommandResume      = "resume"
	CommandReload      = "reload"
	CommandMode        = "mode"
	CommandSensitivity = "sensitivity"
	CommandSet         = "set"
	CommandPack        = "pack"
	CommandStart       = "start"
	CommandStop        = "stop"
	CommandRestart     = "restart"
)

type Command struct {
	Name            string
	RuntimeDir      string
	LaunchAgentsDir string
	PacksDir        string
	JSON            bool
	Request         *ipc.ControlRequest
	PackAction      string
	PackName        string
	PackSourceDir   string
}
