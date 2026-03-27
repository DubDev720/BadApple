package main

import (
	"flag"
	"fmt"
	"os"

	"spank/internal/media"
	"spank/internal/packs"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}

	switch os.Args[1] {
	case "normalize-dir":
		if err := normalizeDir(os.Args[2:]); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	case "validate-embedded":
		if err := validateEmbedded(); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	default:
		usage()
		os.Exit(2)
	}
}

func normalizeDir(args []string) error {
	fs := flag.NewFlagSet("normalize-dir", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	var sourceDir string
	var outputDir string
	fs.StringVar(&sourceDir, "source-dir", "", "Directory containing source audio files")
	fs.StringVar(&outputDir, "output-dir", "", "Directory for normalized wav output")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if sourceDir == "" || outputDir == "" {
		return fmt.Errorf("normalize-dir requires -source-dir and -output-dir")
	}
	count, err := packs.NormalizeDirectory(sourceDir, outputDir)
	if err != nil {
		return err
	}
	fmt.Printf("normalized %d files into %s\n", count, outputDir)
	fmt.Printf("canonical wav: %d Hz, %d-bit PCM, %d channels, max %ds\n",
		media.CanonicalSampleRate,
		media.CanonicalBits,
		media.CanonicalChannels,
		media.MaxClipDurationSec,
	)
	return nil
}

func validateEmbedded() error {
	if err := validateEmbeddedMedia(); err != nil {
		return err
	}
	fmt.Printf("embedded media validated: %d Hz, %d-bit PCM, %d channels, max %ds\n",
		media.CanonicalSampleRate,
		media.CanonicalBits,
		media.CanonicalChannels,
		media.MaxClipDurationSec,
	)
	return nil
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage:")
	fmt.Fprintln(os.Stderr, "  packtool normalize-dir -source-dir <dir> -output-dir <dir>")
	fmt.Fprintln(os.Stderr, "  packtool validate-embedded")
}
