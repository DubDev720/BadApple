/*
 * Copyright (C) 2026 Jocelyn Dubeau
 *
 * This file is part of BadApple (aka Spank 2.0).
 *
 * BadApple is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * BadApple is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with BadApple.  If not, see <https://www.gnu.org/licenses/>.
 */

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#include <stdlib.h>
#include <string.h>

static char *spank_copy_error_message(NSError *error, NSString *fallback) {
    NSString *message = nil;
    if (error != nil && error.localizedDescription.length > 0) {
        message = error.localizedDescription;
    } else {
        message = fallback;
    }
    return strdup(message.UTF8String);
}

char *spank_play_buffer(const void *bytes, int length, double volume, double rate) {
    @autoreleasepool {
        if (bytes == NULL || length <= 0) {
            return strdup("empty clip data");
        }

        NSData *data = [NSData dataWithBytes:bytes length:(NSUInteger)length];
        NSError *error = nil;
        AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithData:data error:&error];
        if (player == nil) {
            return spank_copy_error_message(error, @"failed to initialize AVAudioPlayer");
        }

        player.volume = (float)volume;
        player.enableRate = YES;
        player.rate = (float)rate;

        if (![player prepareToPlay]) {
            return strdup("AVAudioPlayer failed to prepare clip");
        }
        if (![player play]) {
            return strdup("AVAudioPlayer failed to start playback");
        }

        while (player.isPlaying) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        return NULL;
    }
}

void spank_free_error(char *message) {
    free(message);
}
