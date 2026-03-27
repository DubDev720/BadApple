package media

import (
	"embed"
	"math/rand"
	"strings"
)

type Source string

const (
	SourceSexy   Source = "sexy"
	SourceCustom Source = "custom"
	SourceChaos  Source = "chaos"
)

type Strategy string

const (
	StrategyRandom     Strategy = "random"
	StrategyEscalation Strategy = "escalation"
)

type Clip struct {
	Name string
	Path string
}

type Provider struct {
	fs       embed.FS
	clips    map[Source][]Clip
	clipData map[string][]byte
	random   *rand.Rand
}

func NormalizeSourceName(name string) string {
	return strings.ToLower(strings.TrimSpace(name))
}

func ValidateRuntimePackName(name string) error {
	name = NormalizeSourceName(name)
	if name == "" {
		return errInvalidPackName("pack name is required")
	}
	if isReservedSourceName(name) {
		return errInvalidPackName("pack name is reserved")
	}
	for i, r := range name {
		switch {
		case r >= 'a' && r <= 'z':
		case r >= '0' && r <= '9' && i > 0:
		case (r == '-' || r == '_') && i > 0:
		default:
			return errInvalidPackName("pack names must match [a-z][a-z0-9_-]*")
		}
	}
	return nil
}

func isReservedSourceName(name string) bool {
	switch NormalizeSourceName(name) {
	case string(SourceSexy), string(SourceCustom), string(SourceChaos), "pain", "halo":
		return true
	default:
		return false
	}
}

type errInvalidPackName string

func (e errInvalidPackName) Error() string {
	return string(e)
}
