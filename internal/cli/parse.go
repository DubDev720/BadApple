package cli

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"strconv"
	"strings"

	"spank/internal/ipc"
	"spank/internal/paths"
)

func Parse(args []string) (Command, error) {
	if len(args) == 0 {
		return Command{
			Name:            CommandStatus,
			RuntimeDir:      paths.DefaultRuntimeDir(),
			LaunchAgentsDir: paths.DefaultLaunchAgentsDir(),
			Request:         &ipc.ControlRequest{Command: "status"},
		}, nil
	}

	switch args[0] {
	case CommandHelp, "-h", "--help":
		return defaultCommand(CommandHelp), nil
	}

	if strings.HasPrefix(args[0], "-") {
		return parseLegacy(args)
	}

	return parseSubcommand(args)
}

func parseSubcommand(args []string) (Command, error) {
	switch args[0] {
	case CommandHelp:
		return defaultCommand(CommandHelp), nil
	case CommandStatus:
		return parseStatus(args[1:])
	case CommandPause:
		return parseSimpleRequest(CommandPause, args[1:])
	case CommandResume:
		return parseSimpleRequest(CommandResume, args[1:])
	case CommandReload:
		return parseSimpleRequest(CommandReload, args[1:])
	case CommandMode:
		return parseMode(args[1:])
	case CommandSensitivity:
		return parseSensitivity(args[1:])
	case CommandSet:
		return parseSet(args[1:])
	case CommandPack:
		return parsePack(args[1:])
	case CommandStart, CommandStop, CommandRestart:
		return parseServiceCommand(args[0], args[1:])
	default:
		return Command{}, fmt.Errorf("unknown command %q", args[0])
	}
}

func parseStatus(args []string) (Command, error) {
	fs := newFlagSet(CommandStatus)
	cmd := defaultCommand(CommandStatus)
	fs.StringVar(&cmd.RuntimeDir, "runtime-dir", cmd.RuntimeDir, "Runtime directory for daemon sockets")
	fs.StringVar(&cmd.LaunchAgentsDir, "launch-agents-dir", cmd.LaunchAgentsDir, "Directory containing launch agent plists")
	fs.BoolVar(&cmd.JSON, "json", false, "Print raw JSON daemon response")
	if err := fs.Parse(args); err != nil {
		return Command{}, err
	}
	if fs.NArg() != 0 {
		return Command{}, errors.New("status takes no positional arguments")
	}
	cmd.Request = &ipc.ControlRequest{Command: "status"}
	return cmd, nil
}

func parseSimpleRequest(name string, args []string) (Command, error) {
	fs := newFlagSet(name)
	cmd := defaultCommand(name)
	fs.StringVar(&cmd.RuntimeDir, "runtime-dir", cmd.RuntimeDir, "Runtime directory for daemon sockets")
	if err := fs.Parse(args); err != nil {
		return Command{}, err
	}
	if fs.NArg() != 0 {
		return Command{}, fmt.Errorf("%s takes no positional arguments", name)
	}
	cmd.Request = &ipc.ControlRequest{Command: name}
	return cmd, nil
}

func parseMode(args []string) (Command, error) {
	fs := newFlagSet(CommandMode)
	cmd := defaultCommand(CommandMode)
	fs.StringVar(&cmd.RuntimeDir, "runtime-dir", cmd.RuntimeDir, "Runtime directory for daemon sockets")
	if err := fs.Parse(args); err != nil {
		return Command{}, err
	}
	if fs.NArg() < 1 || fs.NArg() > 2 {
		return Command{}, errors.New("mode requires <source> and optional [strategy]")
	}
	source := fs.Arg(0)
	req := &ipc.ControlRequest{
		Command: "update",
		Update:  &ipc.ConfigUpdate{Source: &source},
	}
	if fs.NArg() == 2 {
		strategy := fs.Arg(1)
		req.Update.Strategy = &strategy
	}
	cmd.Request = req
	return cmd, nil
}

func parseSensitivity(args []string) (Command, error) {
	fs := newFlagSet(CommandSensitivity)
	cmd := defaultCommand(CommandSensitivity)
	fs.StringVar(&cmd.RuntimeDir, "runtime-dir", cmd.RuntimeDir, "Runtime directory for daemon sockets")
	if err := fs.Parse(args); err != nil {
		return Command{}, err
	}
	if fs.NArg() != 1 {
		return Command{}, errors.New("sensitivity requires <low|medium|high|number>")
	}
	value, err := parseSensitivityValue(fs.Arg(0))
	if err != nil {
		return Command{}, err
	}
	cmd.Request = &ipc.ControlRequest{
		Command: "update",
		Update:  &ipc.ConfigUpdate{MinAmplitude: &value},
	}
	return cmd, nil
}

func parseSet(args []string) (Command, error) {
	fs := newFlagSet(CommandSet)
	cmd := defaultCommand(CommandSet)
	var (
		source        string
		strategy      string
		amplitude     float64
		cooldown      int
		speed         float64
		volumeScaling bool
		setVolume     bool
	)
	fs.StringVar(&cmd.RuntimeDir, "runtime-dir", cmd.RuntimeDir, "Runtime directory for daemon sockets")
	fs.StringVar(&source, "source", "", "Source to set")
	fs.StringVar(&strategy, "strategy", "", "Strategy to set")
	fs.Float64Var(&amplitude, "min-amplitude", -1, "Amplitude threshold to set")
	fs.IntVar(&cooldown, "cooldown", -1, "Cooldown in milliseconds to set")
	fs.Float64Var(&speed, "speed", -1, "Playback speed ratio to set")
	fs.BoolVar(&volumeScaling, "volume-scaling", false, "Volume scaling value to set")
	fs.BoolVar(&setVolume, "set-volume-scaling", false, "Whether to include volume scaling in the update")
	if err := fs.Parse(args); err != nil {
		return Command{}, err
	}
	if fs.NArg() != 0 {
		return Command{}, errors.New("set accepts flags only")
	}
	update := &ipc.ConfigUpdate{}
	var changed bool
	if source != "" {
		update.Source = &source
		changed = true
	}
	if strategy != "" {
		update.Strategy = &strategy
		changed = true
	}
	if amplitude >= 0 {
		update.MinAmplitude = &amplitude
		changed = true
	}
	if cooldown >= 0 {
		update.CooldownMs = &cooldown
		changed = true
	}
	if speed >= 0 {
		update.SpeedRatio = &speed
		changed = true
	}
	if setVolume {
		update.VolumeScaling = &volumeScaling
		changed = true
	}
	if !changed {
		return Command{}, errors.New("set requires at least one update flag")
	}
	cmd.Request = &ipc.ControlRequest{Command: "update", Update: update}
	return cmd, nil
}

func parsePack(args []string) (Command, error) {
	fs := newFlagSet(CommandPack)
	cmd := defaultCommand(CommandPack)
	fs.StringVar(&cmd.PacksDir, "packs-dir", cmd.PacksDir, "Directory containing runtime media packs")
	if err := fs.Parse(args); err != nil {
		return Command{}, err
	}
	if fs.NArg() < 1 {
		return Command{}, errors.New("pack requires a subcommand: list|install|remove")
	}
	cmd.PackAction = fs.Arg(0)
	switch cmd.PackAction {
	case "list":
		if fs.NArg() != 1 {
			return Command{}, errors.New("pack list takes no additional arguments")
		}
	case "install":
		if fs.NArg() != 3 {
			return Command{}, errors.New("pack install requires <name> <wav-dir>")
		}
		cmd.PackName = fs.Arg(1)
		cmd.PackSourceDir = fs.Arg(2)
	case "remove":
		if fs.NArg() != 2 {
			return Command{}, errors.New("pack remove requires <name>")
		}
		cmd.PackName = fs.Arg(1)
	default:
		return Command{}, fmt.Errorf("unknown pack subcommand %q", cmd.PackAction)
	}
	return cmd, nil
}

func parseServiceCommand(name string, args []string) (Command, error) {
	fs := newFlagSet(name)
	cmd := defaultCommand(name)
	fs.StringVar(&cmd.LaunchAgentsDir, "launch-agents-dir", cmd.LaunchAgentsDir, "Directory containing launch agent plists")
	if err := fs.Parse(args); err != nil {
		return Command{}, err
	}
	if fs.NArg() != 0 {
		return Command{}, fmt.Errorf("%s takes no positional arguments", name)
	}
	return cmd, nil
}

func parseLegacy(args []string) (Command, error) {
	if len(args) == 1 && (args[0] == "-h" || args[0] == "--help") {
		return defaultCommand(CommandHelp), nil
	}
	fs := newFlagSet("legacy")
	cmd := defaultCommand(CommandStatus)
	var (
		command       string
		source        string
		strategy      string
		amplitude     float64
		cooldown      int
		speed         float64
		volumeScaling bool
		setVolume     bool
	)
	fs.StringVar(&cmd.RuntimeDir, "runtime-dir", cmd.RuntimeDir, "Runtime directory for daemon sockets")
	fs.StringVar(&command, "command", "status", "Command to send: status|pause|resume|reload|update")
	fs.StringVar(&source, "source", "", "Source to set during update")
	fs.StringVar(&strategy, "strategy", "", "Strategy to set during update")
	fs.Float64Var(&amplitude, "min-amplitude", -1, "Amplitude threshold to set during update")
	fs.IntVar(&cooldown, "cooldown", -1, "Cooldown in milliseconds to set during update")
	fs.Float64Var(&speed, "speed", -1, "Playback speed to set during update")
	fs.BoolVar(&volumeScaling, "volume-scaling", false, "Volume scaling value to set during update")
	fs.BoolVar(&setVolume, "set-volume-scaling", false, "Whether to include volume-scaling in update")
	fs.BoolVar(&cmd.JSON, "json", true, "Print raw JSON daemon response")
	if err := fs.Parse(args); err != nil {
		return Command{}, err
	}
	if fs.NArg() != 0 {
		return Command{}, errors.New("legacy flag mode does not accept positional arguments")
	}
	cmd.Name = command
	req := &ipc.ControlRequest{Command: command}
	if command == "update" {
		req.Update = &ipc.ConfigUpdate{}
		if source != "" {
			req.Update.Source = &source
		}
		if strategy != "" {
			req.Update.Strategy = &strategy
		}
		if amplitude >= 0 {
			req.Update.MinAmplitude = &amplitude
		}
		if cooldown >= 0 {
			req.Update.CooldownMs = &cooldown
		}
		if speed >= 0 {
			req.Update.SpeedRatio = &speed
		}
		if setVolume {
			req.Update.VolumeScaling = &volumeScaling
		}
	}
	cmd.Request = req
	return cmd, nil
}

func parseSensitivityValue(value string) (float64, error) {
	switch strings.ToLower(value) {
	case "low":
		return 0.33, nil
	case "medium", "default":
		return 0.28, nil
	case "high":
		return 0.23, nil
	}
	parsed, err := strconv.ParseFloat(value, 64)
	if err != nil {
		return 0, fmt.Errorf("invalid sensitivity %q", value)
	}
	return parsed, nil
}

func defaultCommand(name string) Command {
	return Command{
		Name:            name,
		RuntimeDir:      paths.DefaultRuntimeDir(),
		LaunchAgentsDir: paths.DefaultLaunchAgentsDir(),
		PacksDir:        paths.DefaultPacksDir(),
	}
}

func newFlagSet(name string) *flag.FlagSet {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	return fs
}
