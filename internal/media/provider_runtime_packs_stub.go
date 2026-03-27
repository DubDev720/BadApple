//go:build embed_media && !runtime_media_packs

package media

func loadOptionalRuntimePacks(_ *Provider) error {
	return nil
}
