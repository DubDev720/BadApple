package media

import (
	"encoding/binary"
	"fmt"
)

const (
	CanonicalSampleRate = 48000
	CanonicalChannels   = 2
	CanonicalBits       = 16
	MaxClipDurationSec  = 10
)

type ValidationError struct {
	Clip string
	Err  error
}

func (e *ValidationError) Error() string {
	return fmt.Sprintf("validate clip %s: %v", e.Clip, e.Err)
}

func (e *ValidationError) Unwrap() error {
	return e.Err
}

func ValidateClip(clip Clip, data []byte) (err error) {
	defer func() {
		if r := recover(); r != nil {
			err = &ValidationError{
				Clip: clip.Name,
				Err:  fmt.Errorf("panic during validation: %v", r),
			}
		}
	}()

	if len(data) < 44 {
		return &ValidationError{Clip: clip.Name, Err: fmt.Errorf("clip too short for WAV header")}
	}
	if string(data[0:4]) != "RIFF" {
		return &ValidationError{Clip: clip.Name, Err: fmt.Errorf("missing RIFF header")}
	}
	if string(data[8:12]) != "WAVE" {
		return &ValidationError{Clip: clip.Name, Err: fmt.Errorf("missing WAVE signature")}
	}

	riffSize := binary.LittleEndian.Uint32(data[4:8])
	if int(riffSize)+8 > len(data) {
		return &ValidationError{Clip: clip.Name, Err: fmt.Errorf("RIFF size exceeds clip length")}
	}

	var (
		offset        = 12
		hasFmt        bool
		hasData       bool
		dataSize      uint32
		audioFormat   uint16
		channelCount  uint16
		sampleRate    uint32
		byteRate      uint32
		blockAlign    uint16
		bitsPerSample uint16
	)
	for offset+8 <= len(data) {
		chunkID := string(data[offset : offset+4])
		chunkSize := binary.LittleEndian.Uint32(data[offset+4 : offset+8])
		offset += 8
		if offset+int(chunkSize) > len(data) {
			return &ValidationError{Clip: clip.Name, Err: fmt.Errorf("chunk %s exceeds clip length", chunkID)}
		}
		switch chunkID {
		case "fmt ":
			hasFmt = true
			if chunkSize < 16 {
				return &ValidationError{Clip: clip.Name, Err: fmt.Errorf("fmt chunk too small")}
			}
			audioFormat = binary.LittleEndian.Uint16(data[offset : offset+2])
			channelCount = binary.LittleEndian.Uint16(data[offset+2 : offset+4])
			sampleRate = binary.LittleEndian.Uint32(data[offset+4 : offset+8])
			byteRate = binary.LittleEndian.Uint32(data[offset+8 : offset+12])
			blockAlign = binary.LittleEndian.Uint16(data[offset+12 : offset+14])
			bitsPerSample = binary.LittleEndian.Uint16(data[offset+14 : offset+16])
		case "data":
			hasData = true
			dataSize = chunkSize
		}
		offset += int(chunkSize)
		if chunkSize%2 == 1 && offset < len(data) {
			offset++
		}
	}

	if !hasFmt {
		return &ValidationError{Clip: clip.Name, Err: fmt.Errorf("missing fmt chunk")}
	}
	if !hasData || dataSize == 0 {
		return &ValidationError{Clip: clip.Name, Err: fmt.Errorf("missing data chunk")}
	}
	if audioFormat != 1 {
		return &ValidationError{Clip: clip.Name, Err: fmt.Errorf("unsupported wav format %d; expected PCM", audioFormat)}
	}
	if channelCount != CanonicalChannels {
		return &ValidationError{Clip: clip.Name, Err: fmt.Errorf("expected %d channels, got %d", CanonicalChannels, channelCount)}
	}
	if sampleRate != CanonicalSampleRate {
		return &ValidationError{Clip: clip.Name, Err: fmt.Errorf("expected sample rate %d, got %d", CanonicalSampleRate, sampleRate)}
	}
	if bitsPerSample != CanonicalBits {
		return &ValidationError{Clip: clip.Name, Err: fmt.Errorf("expected %d-bit audio, got %d", CanonicalBits, bitsPerSample)}
	}
	expectedBlockAlign := uint16(CanonicalChannels * (CanonicalBits / 8))
	if blockAlign != expectedBlockAlign {
		return &ValidationError{Clip: clip.Name, Err: fmt.Errorf("expected block align %d, got %d", expectedBlockAlign, blockAlign)}
	}
	expectedByteRate := uint32(CanonicalSampleRate) * uint32(expectedBlockAlign)
	if byteRate != expectedByteRate {
		return &ValidationError{Clip: clip.Name, Err: fmt.Errorf("expected byte rate %d, got %d", expectedByteRate, byteRate)}
	}
	if dataSize%uint32(expectedBlockAlign) != 0 {
		return &ValidationError{Clip: clip.Name, Err: fmt.Errorf("data chunk is not aligned to %d-byte PCM frames", expectedBlockAlign)}
	}
	durationSec := float64(dataSize) / float64(expectedByteRate)
	if durationSec > MaxClipDurationSec {
		return &ValidationError{Clip: clip.Name, Err: fmt.Errorf("clip exceeds max duration of %d seconds", MaxClipDurationSec)}
	}
	return nil
}
