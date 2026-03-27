//go:build embed_media

package main

import "spank/internal/media"

func validateEmbeddedMedia() error {
	provider, err := media.NewProvider()
	if err != nil {
		return err
	}
	return provider.Validate()
}
