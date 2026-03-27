//go:build embed_media && !embed_custom_media

package media

func loadOptionalCustom(_ *Provider) error {
	return nil
}
