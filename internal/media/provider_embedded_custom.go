//go:build embed_media && embed_custom_media

package media

import "embed"

//go:embed assets/custom/*.wav
var embeddedCustomAudio embed.FS

func loadOptionalCustom(p *Provider) error {
	return p.loadFromFS(embeddedCustomAudio, SourceCustom, "assets/custom")
}
