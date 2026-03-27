//go:build darwin

package audio

/*
#cgo CFLAGS: -x objective-c -fobjc-arc
#cgo LDFLAGS: -framework Foundation -framework AVFoundation
#include <stdlib.h>

char *spank_play_buffer(const void *bytes, int length, double volume, double rate);
void spank_free_error(char *message);
*/
import "C"

import (
	"context"
	"fmt"
	"log"
)

type nativePlayer struct{}

func newPlayer(workDir string, logger *log.Logger) Player {
	_ = workDir
	_ = logger
	return nativePlayer{}
}

func (nativePlayer) Play(ctx context.Context, clipName string, data []byte, opts PlayOptions) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if len(data) == 0 {
		return fmt.Errorf("play %s: empty clip data", clipName)
	}

	rate := opts.Rate
	if rate <= 0 {
		rate = 1.0
	}

	volume := opts.Volume
	if volume < 0 {
		volume = 0
	}
	if volume > 1 {
		volume = 1
	}

	buffer := C.CBytes(data)
	defer C.free(buffer)

	errMsg := C.spank_play_buffer(buffer, C.int(len(data)), C.double(volume), C.double(rate))
	if errMsg != nil {
		defer C.spank_free_error(errMsg)
		return fmt.Errorf("native playback %s: %s", clipName, C.GoString(errMsg))
	}
	return nil
}
