//go:build !embed_media

package main

import "fmt"

func validateEmbeddedMedia() error {
	return fmt.Errorf("validate-embedded requires the embed_media build tag")
}
