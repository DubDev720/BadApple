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

#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/hid/IOHIDLib.h>
#import <signal.h>
#import <time.h>

static const int kIMUReportLen = 22;
static const int kIMUDecimation = 8;
static const int kIMUDataOffset = 6;
static const int kReportBufSize = 4096;
static const int32_t kReportIntervalUS = 1000;
static const int64_t kPrimaryUsagePageVendor = 0xFF00;
static const int64_t kPrimaryUsageAccel = 3;
static const double kAccelScale = 65536.0;

static CFRunLoopRef gRunLoop = NULL;
static IOHIDDeviceRef gDevice = NULL;
static NSMutableData *gReportBuffer = nil;
static int gAccelDecimation = 0;

static void stopRunLoop(int signalNumber) {
    (void)signalNumber;
    if (gRunLoop != NULL) {
        CFRunLoopStop(gRunLoop);
    }
}

static int64_t currentUnixNano(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + (int64_t)ts.tv_nsec;
}

static CFNumberRef createCFNumber(int32_t value) {
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &value);
}

static BOOL readIntProperty(io_registry_entry_t service, CFStringRef key, int64_t *outValue) {
    CFTypeRef ref = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    if (ref == NULL) {
        return NO;
    }
    BOOL ok = NO;
    if (CFGetTypeID(ref) == CFNumberGetTypeID()) {
        ok = CFNumberGetValue((CFNumberRef)ref, kCFNumberSInt64Type, outValue);
    }
    CFRelease(ref);
    return ok;
}

static kern_return_t wakeSPUDrivers(void) {
    CFMutableDictionaryRef matching = IOServiceMatching("AppleSPUHIDDriver");
    if (matching == NULL) {
        return KERN_FAILURE;
    }

    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator);
    if (kr != KERN_SUCCESS) {
        return kr;
    }

    for (;;) {
        io_registry_entry_t service = IOIteratorNext(iterator);
        if (service == IO_OBJECT_NULL) {
            break;
        }

        CFNumberRef reportingState = createCFNumber(1);
        CFNumberRef powerState = createCFNumber(1);
        CFNumberRef reportInterval = createCFNumber(kReportIntervalUS);
        if (reportingState != NULL) {
            IORegistryEntrySetCFProperty(service, CFSTR("SensorPropertyReportingState"), reportingState);
            CFRelease(reportingState);
        }
        if (powerState != NULL) {
            IORegistryEntrySetCFProperty(service, CFSTR("SensorPropertyPowerState"), powerState);
            CFRelease(powerState);
        }
        if (reportInterval != NULL) {
            IORegistryEntrySetCFProperty(service, CFSTR("ReportInterval"), reportInterval);
            CFRelease(reportInterval);
        }

        IOObjectRelease(service);
    }

    IOObjectRelease(iterator);
    return KERN_SUCCESS;
}

static void emitSample(int32_t x, int32_t y, int32_t z) {
    NSDictionary *payload = @{
        @"type": @"sample",
        @"x": @((double)x / kAccelScale),
        @"y": @((double)y / kAccelScale),
        @"z": @((double)z / kAccelScale),
        @"timestamp_unix_nano": @(currentUnixNano()),
    };

    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&error];
    if (json == nil || error != nil) {
        return;
    }

    NSFileHandle *stdoutHandle = [NSFileHandle fileHandleWithStandardOutput];
    [stdoutHandle writeData:json];
    [stdoutHandle writeData:[NSData dataWithBytes:"\n" length:1]];
}

static void reportCallback(void *context,
                           IOReturn result,
                           void *sender,
                           IOHIDReportType type,
                           uint32_t reportID,
                           uint8_t *report,
                           CFIndex reportLength) {
    (void)context;
    (void)result;
    (void)sender;
    (void)type;
    (void)reportID;

    if (report == NULL || reportLength != kIMUReportLen) {
        return;
    }

    gAccelDecimation += 1;
    if (gAccelDecimation < kIMUDecimation) {
        return;
    }
    gAccelDecimation = 0;

    int32_t x = 0;
    int32_t y = 0;
    int32_t z = 0;
    memcpy(&x, report + kIMUDataOffset, sizeof(int32_t));
    memcpy(&y, report + kIMUDataOffset + 4, sizeof(int32_t));
    memcpy(&z, report + kIMUDataOffset + 8, sizeof(int32_t));

    emitSample(x, y, z);
}

static NSError *registerAccelerometerDevice(void) {
    CFMutableDictionaryRef matching = IOServiceMatching("AppleSPUHIDDevice");
    if (matching == NULL) {
        return [NSError errorWithDomain:@"spank.sensor" code:1 userInfo:@{NSLocalizedDescriptionKey: @"IOServiceMatching returned NULL"}];
    }

    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator);
    if (kr != KERN_SUCCESS) {
        return [NSError errorWithDomain:@"spank.sensor" code:(NSInteger)kr userInfo:@{NSLocalizedDescriptionKey: @"IOServiceGetMatchingServices failed"}];
    }

    NSError *lastError = nil;
    BOOL found = NO;
    for (;;) {
        io_registry_entry_t service = IOIteratorNext(iterator);
        if (service == IO_OBJECT_NULL) {
            break;
        }

        int64_t usagePage = 0;
        int64_t usage = 0;
        BOOL haveUsagePage = readIntProperty(service, CFSTR("PrimaryUsagePage"), &usagePage);
        BOOL haveUsage = readIntProperty(service, CFSTR("PrimaryUsage"), &usage);
        if (!haveUsagePage || !haveUsage || usagePage != kPrimaryUsagePageVendor || usage != kPrimaryUsageAccel) {
            IOObjectRelease(service);
            continue;
        }

        IOHIDDeviceRef device = IOHIDDeviceCreate(kCFAllocatorDefault, service);
        IOReturn openResult = kIOReturnError;
        if (device != NULL) {
            openResult = IOHIDDeviceOpen(device, kIOHIDOptionsTypeNone);
        }
        if (device != NULL && openResult == kIOReturnSuccess) {
            gDevice = device;
            gReportBuffer = [NSMutableData dataWithLength:kReportBufSize];
            IOHIDDeviceRegisterInputReportCallback(gDevice,
                                                   (uint8_t *)[gReportBuffer mutableBytes],
                                                   kReportBufSize,
                                                   reportCallback,
                                                   NULL);
            IOHIDDeviceScheduleWithRunLoop(gDevice, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
            found = YES;
            IOObjectRelease(service);
            break;
        }

        if (device != NULL) {
            CFRelease(device);
        }
        lastError = [NSError errorWithDomain:@"spank.sensor"
                                        code:(NSInteger)openResult
                                    userInfo:@{NSLocalizedDescriptionKey: @"failed to open accelerometer HID device"}];
        IOObjectRelease(service);
    }

    IOObjectRelease(iterator);

    if (!found) {
        if (lastError != nil) {
            return lastError;
        }
        return [NSError errorWithDomain:@"spank.sensor" code:2 userInfo:@{NSLocalizedDescriptionKey: @"no accelerometer HID device found"}];
    }
    return nil;
}

static int runSampleStream(void) {
    if (wakeSPUDrivers() != KERN_SUCCESS) {
        fprintf(stderr, "wake SPU drivers failed\n");
        return 1;
    }

    NSError *error = registerAccelerometerDevice();
    if (error != nil) {
        fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
        return 1;
    }

    signal(SIGINT, stopRunLoop);
    signal(SIGTERM, stopRunLoop);
    gRunLoop = CFRunLoopGetCurrent();

    while (1) {
        SInt32 result = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
        if (result == kCFRunLoopRunStopped || result == kCFRunLoopRunFinished) {
            break;
        }
    }

    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "usage: sensor-stream samples\n");
            return 1;
        }

        NSString *command = [NSString stringWithUTF8String:argv[1]];
        if ([command isEqualToString:@"samples"]) {
            return runSampleStream();
        }
        if ([command isEqualToString:@"help"] || [command isEqualToString:@"-h"] || [command isEqualToString:@"--help"]) {
            fprintf(stderr, "usage: sensor-stream samples\n");
            return 1;
        }

        fprintf(stderr, "unknown command %s\n", argv[1]);
        return 1;
    }
}
