//go:build embed_media

package media

import (
	"embed"
	"fmt"
	"io/fs"
	"math"
	"math/rand"
	"path/filepath"
	"sort"
	"time"
)

//go:embed assets/sexy/*.wav
var embeddedAudio embed.FS

func NewProvider() (*Provider, error) {
	p := &Provider{
		fs:       embeddedAudio,
		clips:    make(map[Source][]Clip),
		clipData: make(map[string][]byte),
		random:   rand.New(rand.NewSource(time.Now().UnixNano())),
	}
	if err := p.loadFromFS(embeddedAudio, SourceSexy, "assets/sexy"); err != nil {
		return nil, err
	}
	if err := loadOptionalCustom(p); err != nil {
		return nil, err
	}
	if err := loadOptionalRuntimePacks(p); err != nil {
		return nil, err
	}
	return p, p.Validate()
}

func (p *Provider) loadFromFS(fsys fs.FS, source Source, dir string) error {
	entries, err := fs.ReadDir(fsys, dir)
	if err != nil {
		return fmt.Errorf("read %s: %w", dir, err)
	}
	var clips []Clip
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		if filepath.Ext(name) != ".wav" {
			continue
		}
		path := dir + "/" + name
		data, err := fs.ReadFile(fsys, path)
		if err != nil {
			return fmt.Errorf("read %s: %w", path, err)
		}
		p.clipData[path] = data
		clips = append(clips, Clip{
			Name: name,
			Path: path,
		})
	}
	sort.Slice(clips, func(i, j int) bool { return clips[i].Name < clips[j].Name })
	p.clips[source] = clips
	return nil
}

func (p *Provider) Validate() error {
	required := []Source{SourceSexy}
	for _, source := range required {
		clips := p.clips[source]
		if len(clips) == 0 {
			return fmt.Errorf("embedded source %q has no clips", source)
		}
	}
	for source, clips := range p.clips {
		if len(clips) == 0 {
			return fmt.Errorf("source %q has no clips", source)
		}
		for _, clip := range clips {
			data, err := p.Read(clip)
			if err != nil {
				return fmt.Errorf("read embedded clip %s: %w", clip.Path, err)
			}
			if err := ValidateClip(clip, data); err != nil {
				return err
			}
		}
	}
	return nil
}

func (p *Provider) Clips(source Source) ([]Clip, error) {
	if source == SourceChaos {
		out := make([]Clip, 0)
		for sourceName, clips := range p.clips {
			if sourceName == SourceChaos {
				continue
			}
			out = append(out, clips...)
		}
		if len(out) == 0 {
			return nil, fmt.Errorf("source %q has no clips", source)
		}
		return out, nil
	}
	clips := p.clips[source]
	if len(clips) == 0 {
		return nil, fmt.Errorf("source %q has no clips", source)
	}
	return clips, nil
}

func (p *Provider) ValidateSelection(source Source, strategy Strategy) error {
	switch strategy {
	case StrategyRandom, StrategyEscalation:
	default:
		return fmt.Errorf("unsupported strategy %q", strategy)
	}
	if source == "" {
		return fmt.Errorf("source is required")
	}
	if source == SourceChaos && strategy != StrategyRandom {
		return fmt.Errorf("source %q only supports strategy %q", source, StrategyRandom)
	}
	if _, err := p.Clips(source); err != nil {
		return err
	}
	return nil
}

func (p *Provider) RandomClip(source Source) (Clip, error) {
	clips, err := p.Clips(source)
	if err != nil {
		return Clip{}, err
	}
	return clips[p.random.Intn(len(clips))], nil
}

func (p *Provider) EscalationClip(source Source, score float64, cooldown time.Duration) (Clip, error) {
	clips, err := p.Clips(source)
	if err != nil {
		return Clip{}, err
	}
	if len(clips) == 1 {
		return clips[0], nil
	}
	const decayHalfLife = 30.0
	cooldownSec := cooldown.Seconds()
	ssMax := 1.0 / (1.0 - math.Pow(0.5, cooldownSec/decayHalfLife))
	scale := (ssMax - 1) / math.Log(float64(len(clips)+1))
	maxIdx := len(clips) - 1
	idx := minInt(int(float64(len(clips))*(1.0-math.Exp(-(score-1)/scale))), maxIdx)
	if idx < 0 {
		idx = 0
	}
	return clips[idx], nil
}

func (p *Provider) Read(clip Clip) ([]byte, error) {
	data, ok := p.clipData[clip.Path]
	if !ok {
		return nil, fmt.Errorf("clip %q not loaded", clip.Path)
	}
	return data, nil
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}
