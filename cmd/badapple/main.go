package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"spank/internal/cli"
	"spank/internal/ipc"
	"spank/internal/media"
	"spank/internal/packs"
)

const (
	daemonLabel = "com.spank.spankd"
	helperLabel = "com.spank.spank-sensor-helper"
)

type serviceState struct {
	Label string
	State string
}

func main() {
	cmd, err := cli.Parse(os.Args[1:])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		fmt.Fprintln(os.Stderr, "")
		fmt.Fprint(os.Stderr, cli.Usage)
		os.Exit(2)
	}

	switch cmd.Name {
	case cli.CommandHelp:
		fmt.Print(cli.Usage)
		return
	case cli.CommandPack:
		err = runPackCommand(cmd)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	case cli.CommandStart:
		err = startServices(cmd.LaunchAgentsDir)
	case cli.CommandStop:
		err = stopServices()
	case cli.CommandRestart:
		err = restartServices(cmd.LaunchAgentsDir)
	default:
		err = runDaemonCommand(cmd)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func runPackCommand(cmd cli.Command) error {
	switch cmd.PackAction {
	case "list":
		infos, err := packs.List(cmd.PacksDir)
		if err != nil {
			return err
		}
		fmt.Printf("Runtime packs dir: %s\n", cmd.PacksDir)
		if len(infos) == 0 {
			fmt.Println("No runtime packs installed.")
			return nil
		}
		for _, info := range infos {
			fmt.Printf("- %s (%d clips)\n", info.Name, info.ClipCount)
		}
		return nil
	case "install":
		info, err := packs.Install(cmd.PacksDir, cmd.PackName, cmd.PackSourceDir)
		if err != nil {
			return err
		}
		fmt.Printf("Installed runtime pack %q with %d clips.\n", info.Name, info.ClipCount)
		fmt.Printf("Pack path: %s\n", info.Path)
		fmt.Printf("Canonical wav: %d Hz, %d-bit PCM, %d channels, max %ds\n",
			media.CanonicalSampleRate,
			media.CanonicalBits,
			media.CanonicalChannels,
			media.MaxClipDurationSec,
		)
		fmt.Println("To use it live, run a daemon build with the runtime_media_packs tag and restart:")
		fmt.Println("  sudo SPANK_BUILD_TAGS='embed_media runtime_media_packs' ./scripts/dev_reinstall.sh")
		fmt.Printf("  badapple mode %s random\n", info.Name)
		return nil
	case "remove":
		if err := packs.Remove(cmd.PacksDir, cmd.PackName); err != nil {
			return err
		}
		fmt.Printf("Removed runtime pack %q.\n", cmd.PackName)
		return nil
	default:
		return fmt.Errorf("unknown pack subcommand %q", cmd.PackAction)
	}
}

func runDaemonCommand(cmd cli.Command) error {
	if cmd.Request == nil {
		return errors.New("missing daemon request")
	}

	resp, err := requestDaemon(cmd.RuntimeDir, *cmd.Request)
	if err != nil {
		if cmd.Name == cli.CommandStatus && !cmd.JSON {
			return printStatusWithServices(cmd.RuntimeDir)
		}
		return err
	}

	if cmd.JSON {
		if err := printJSON(resp); err != nil {
			return err
		}
		if resp.Error != "" {
			return errors.New(resp.Error)
		}
		return nil
	}

	if resp.Error != "" {
		return errors.New(resp.Error)
	}

	switch cmd.Name {
	case cli.CommandStatus:
		return printStatus(cmd.RuntimeDir, resp)
	default:
		return printActionResult(cmd.Name, resp)
	}
}

func requestDaemon(runtimeDir string, req ipc.ControlRequest) (ipc.ControlResponse, error) {
	var resp ipc.ControlResponse
	socketPath := filepath.Join(runtimeDir, "spankctl.sock")
	if err := ipc.Request(socketPath, req, &resp); err != nil {
		return resp, err
	}
	return resp, nil
}

func printJSON(resp ipc.ControlResponse) error {
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(resp)
}

func printStatus(runtimeDir string, resp ipc.ControlResponse) error {
	states := collectServiceStates()
	fmt.Printf("Daemon: %s\n", firstServiceState(states, daemonLabel))
	fmt.Printf("Helper: %s\n", firstServiceState(states, helperLabel))
	fmt.Printf("Runtime: %s\n", runtimeDir)
	if resp.Config == nil {
		return nil
	}
	fmt.Printf("Paused: %t\n", resp.Paused)
	fmt.Printf("Source: %s\n", resp.Config.Source)
	fmt.Printf("Strategy: %s\n", resp.Config.Strategy)
	fmt.Printf("Sensitivity: %s (min-amplitude %.3f)\n", sensitivityLabel(resp.Config.MinAmplitude), resp.Config.MinAmplitude)
	fmt.Printf("Sensitivity presets: high=0.23 medium=0.28 low=0.33\n")
	fmt.Printf("Cooldown: %dms\n", resp.Config.CooldownMs)
	fmt.Printf("Speed: %.2fx\n", resp.Config.SpeedRatio)
	fmt.Printf("Volume scaling: %t\n", resp.Config.VolumeScaling)
	return nil
}

func printStatusWithServices(runtimeDir string) error {
	states := collectServiceStates()
	fmt.Printf("Daemon: %s\n", firstServiceState(states, daemonLabel))
	fmt.Printf("Helper: %s\n", firstServiceState(states, helperLabel))
	fmt.Printf("Runtime: %s\n", runtimeDir)
	fmt.Println("Control: unavailable")
	return errors.New("daemon control socket is unavailable")
}

func printActionResult(name string, resp ipc.ControlResponse) error {
	if resp.Config == nil {
		fmt.Printf("%s: ok\n", name)
		return nil
	}
	switch name {
	case cli.CommandPause, cli.CommandResume:
		fmt.Printf("%s: ok (paused=%t)\n", name, resp.Paused)
	case cli.CommandReload, cli.CommandMode, cli.CommandSensitivity, cli.CommandSet:
		fmt.Printf("%s: ok\n", name)
		fmt.Printf("source=%s strategy=%s min_amplitude=%.3f cooldown_ms=%d speed_ratio=%.2f volume_scaling=%t paused=%t\n",
			resp.Config.Source,
			resp.Config.Strategy,
			resp.Config.MinAmplitude,
			resp.Config.CooldownMs,
			resp.Config.SpeedRatio,
			resp.Config.VolumeScaling,
			resp.Paused,
		)
		fmt.Printf("sensitivity_presets high=0.23 medium=0.28 low=0.33\n")
	default:
		fmt.Printf("%s: ok\n", name)
	}
	return nil
}

func startServices(launchAgentsDir string) error {
	if err := bootoutServices(); err != nil {
		var exitErr *exec.ExitError
		if !errors.As(err, &exitErr) {
			return err
		}
	}
	return bootstrapServices(launchAgentsDir)
}

func bootstrapServices(launchAgentsDir string) error {
	if err := launchctl("bootstrap", guiDomain(), filepath.Join(launchAgentsDir, daemonLabel+".plist")); err != nil {
		return err
	}
	if err := launchctl("bootstrap", guiDomain(), filepath.Join(launchAgentsDir, helperLabel+".plist")); err != nil {
		return err
	}
	if err := launchctl("kickstart", "-k", guiDomain()+"/"+daemonLabel); err != nil {
		return err
	}
	if err := launchctl("kickstart", "-k", guiDomain()+"/"+helperLabel); err != nil {
		return err
	}
	return printServiceSummary()
}

func stopServices() error {
	if err := bootoutServices(); err != nil {
		return err
	}
	return printServiceSummary()
}

func bootoutServices() error {
	var errs []string
	if err := launchctl("bootout", guiDomain()+"/"+helperLabel); err != nil {
		errs = appendIfUnexpected(errs, err)
	}
	if err := launchctl("bootout", guiDomain()+"/"+daemonLabel); err != nil {
		errs = appendIfUnexpected(errs, err)
	}
	if len(errs) > 0 {
		return errors.New(strings.Join(errs, "; "))
	}
	return nil
}

func restartServices(launchAgentsDir string) error {
	if err := bootoutServices(); err != nil {
		var exitErr *exec.ExitError
		if !errors.As(err, &exitErr) && !strings.Contains(err.Error(), "Could not find service") {
			return err
		}
	}
	return bootstrapServices(launchAgentsDir)
}

func printServiceSummary() error {
	states := collectServiceStates()
	fmt.Printf("Daemon: %s\n", firstServiceState(states, daemonLabel))
	fmt.Printf("Helper: %s\n", firstServiceState(states, helperLabel))
	return nil
}

func collectServiceStates() []serviceState {
	return []serviceState{
		{Label: daemonLabel, State: lookupServiceState(daemonLabel)},
		{Label: helperLabel, State: lookupServiceState(helperLabel)},
	}
}

func firstServiceState(states []serviceState, label string) string {
	for _, state := range states {
		if state.Label == label {
			return state.State
		}
	}
	return "unknown"
}

func lookupServiceState(label string) string {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "/bin/launchctl", "print", guiDomain()+"/"+label)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return "not loaded"
	}
	for _, line := range strings.Split(string(output), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "state = ") {
			return strings.TrimPrefix(line, "state = ")
		}
	}
	return "loaded"
}

func guiDomain() string {
	return fmt.Sprintf("gui/%d", os.Getuid())
}

func launchctl(args ...string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "/bin/launchctl", args...)
	output, err := cmd.CombinedOutput()
	if err == nil {
		return nil
	}
	if len(output) == 0 {
		return err
	}
	return fmt.Errorf("%w: %s", err, strings.TrimSpace(string(output)))
}

func appendIfUnexpected(errs []string, err error) []string {
	if err == nil {
		return errs
	}
	if strings.Contains(err.Error(), "Could not find service") || strings.Contains(err.Error(), "No such process") {
		return errs
	}
	return append(errs, err.Error())
}

func sensitivityLabel(value float64) string {
	switch {
	case approxEqual(value, 0.23):
		return "high"
	case approxEqual(value, 0.28):
		return "medium"
	case approxEqual(value, 0.33):
		return "low"
	default:
		return "custom"
	}
}

func approxEqual(a, b float64) bool {
	const epsilon = 0.000001
	delta := a - b
	if delta < 0 {
		delta = -delta
	}
	return delta < epsilon
}
