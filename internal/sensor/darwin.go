//go:build darwin

package sensor

import (
	"context"
	"encoding/binary"
	"fmt"
	"log"
	"os"
	"runtime"
	"time"
	"unsafe"

	"github.com/ebitengine/purego"
)

type AccelSample struct {
	X, Y, Z   float64
	Timestamp time.Time
}

var (
	iokit uintptr
	cf    uintptr
)

var (
	ioServiceMatching              func(name *byte) uintptr
	ioServiceGetMatchingServices   func(mainPort uint32, matching uintptr, existing *uint32) int32
	ioIteratorNext                 func(iterator uint32) uint32
	ioObjectRelease                func(object uint32) int32
	ioRegistryEntryCreateCFProp    func(entry uint32, key uintptr, allocator uintptr, options uint32) uintptr
	ioRegistryEntrySetCFProp       func(entry uint32, key uintptr, value uintptr) int32
	ioHIDDeviceCreate              func(allocator uintptr, service uint32) uintptr
	ioHIDDeviceOpen                func(device uintptr, options int32) int32
	ioHIDDeviceRegisterInputReport func(device uintptr, report uintptr, reportLen int, callback uintptr, context uintptr)
	ioHIDDeviceScheduleWithRL      func(device uintptr, runLoop uintptr, mode uintptr)
)

var (
	cfStringCreateWithCString func(alloc uintptr, cStr *byte, encoding uint32) uintptr
	cfNumberCreate            func(alloc uintptr, theType int32, valuePtr uintptr) uintptr
	cfNumberGetValue          func(number uintptr, theType int32, valuePtr uintptr) bool
	cfRunLoopGetCurrent       func() uintptr
	cfRunLoopRunInMode        func(mode uintptr, seconds float64, returnAfterSourceHandled bool) int32
)

var (
	kCFAllocatorDefault   uintptr
	kCFRunLoopDefaultMode uintptr
)

type streamState struct {
	samples   chan<- AccelSample
	accelDec  int
	reportBuf [][]byte
}

var (
	globalStreamState *streamState
	accelCallbackPtr  uintptr
	debugSensor       = os.Getenv("SPANK_SENSOR_DEBUG") == "1"
)

func debugf(format string, args ...any) {
	if !debugSensor {
		return
	}
	log.Printf("sensor_debug "+format, args...)
}

func init() {
	var err error
	iokit, err = purego.Dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", purego.RTLD_LAZY)
	if err != nil {
		panic(fmt.Sprintf("dlopen IOKit: %v", err))
	}
	cf, err = purego.Dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", purego.RTLD_LAZY)
	if err != nil {
		panic(fmt.Sprintf("dlopen CoreFoundation: %v", err))
	}

	purego.RegisterLibFunc(&ioServiceMatching, iokit, "IOServiceMatching")
	purego.RegisterLibFunc(&ioServiceGetMatchingServices, iokit, "IOServiceGetMatchingServices")
	purego.RegisterLibFunc(&ioIteratorNext, iokit, "IOIteratorNext")
	purego.RegisterLibFunc(&ioObjectRelease, iokit, "IOObjectRelease")
	purego.RegisterLibFunc(&ioRegistryEntryCreateCFProp, iokit, "IORegistryEntryCreateCFProperty")
	purego.RegisterLibFunc(&ioRegistryEntrySetCFProp, iokit, "IORegistryEntrySetCFProperty")
	purego.RegisterLibFunc(&ioHIDDeviceCreate, iokit, "IOHIDDeviceCreate")
	purego.RegisterLibFunc(&ioHIDDeviceOpen, iokit, "IOHIDDeviceOpen")
	purego.RegisterLibFunc(&ioHIDDeviceRegisterInputReport, iokit, "IOHIDDeviceRegisterInputReportCallback")
	purego.RegisterLibFunc(&ioHIDDeviceScheduleWithRL, iokit, "IOHIDDeviceScheduleWithRunLoop")

	purego.RegisterLibFunc(&cfStringCreateWithCString, cf, "CFStringCreateWithCString")
	purego.RegisterLibFunc(&cfNumberCreate, cf, "CFNumberCreate")
	purego.RegisterLibFunc(&cfNumberGetValue, cf, "CFNumberGetValue")
	purego.RegisterLibFunc(&cfRunLoopGetCurrent, cf, "CFRunLoopGetCurrent")
	purego.RegisterLibFunc(&cfRunLoopRunInMode, cf, "CFRunLoopRunInMode")

	kCFAllocatorDefault = derefSymbol(cf, "kCFAllocatorDefault")
	kCFRunLoopDefaultMode = derefSymbol(cf, "kCFRunLoopDefaultMode")
	accelCallbackPtr = purego.NewCallback(accelCallback)
}

func RunAccelerometerStream(ctx context.Context, out chan<- AccelSample) error {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	globalStreamState = &streamState{samples: out}
	defer func() {
		globalStreamState = nil
	}()

	if err := wakeSPUDrivers(); err != nil {
		return fmt.Errorf("wake SPU drivers: %w", err)
	}
	if err := registerAccelerometerDeviceWithRetry(ctx, 10, 100*time.Millisecond); err != nil {
		return fmt.Errorf("register accelerometer device: %w", err)
	}

	for {
		select {
		case <-ctx.Done():
			return nil
		default:
			cfRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false)
		}
	}
}

func registerAccelerometerDeviceWithRetry(ctx context.Context, attempts int, delay time.Duration) error {
	if attempts < 1 {
		attempts = 1
	}

	var lastErr error
	for attempt := 1; attempt <= attempts; attempt++ {
		err := registerAccelerometerDevice()
		if err == nil {
			if attempt > 1 {
				debugf("accelerometer_registration_recovered attempt=%d", attempt)
			}
			return nil
		}
		lastErr = err
		debugf("accelerometer_registration_retry attempt=%d err=%v", attempt, err)
		if attempt == attempts {
			break
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(delay):
		}
	}
	return lastErr
}

func accelCallback(_ uintptr, _ int32, _ uintptr, _ int32, _ uint32, report *byte, length int) {
	state := globalStreamState
	if state == nil || state.samples == nil || length != IMUReportLen {
		return
	}
	state.accelDec++
	if state.accelDec < IMUDecimation {
		return
	}
	state.accelDec = 0

	data := unsafe.Slice(report, length)
	x, y, z := parseIMUReport(data)
	sample := AccelSample{
		X:         float64(x) / AccelScale,
		Y:         float64(y) / AccelScale,
		Z:         float64(z) / AccelScale,
		Timestamp: time.Now(),
	}
	select {
	case state.samples <- sample:
	default:
	}
}

func wakeSPUDrivers() error {
	matching := ioServiceMatching(cStr("AppleSPUHIDDriver"))
	var iterator uint32
	if kr := ioServiceGetMatchingServices(0, matching, &iterator); kr != 0 {
		return fmt.Errorf("IOServiceGetMatchingServices returned %d", kr)
	}
	var count int
	for {
		service := ioIteratorNext(iterator)
		if service == 0 {
			break
		}
		count++
		for _, prop := range []struct {
			key string
			val int32
		}{
			{"SensorPropertyReportingState", 1},
			{"SensorPropertyPowerState", 1},
			{"ReportInterval", ReportIntervalUS},
		} {
			ioRegistryEntrySetCFProp(service, cfStr(prop.key), cfNum32(prop.val))
		}
		ioObjectRelease(service)
	}
	debugf("wake_spu_drivers matched=%d", count)
	return nil
}

func registerAccelerometerDevice() error {
	matching := ioServiceMatching(cStr("AppleSPUHIDDevice"))
	var iterator uint32
	if kr := ioServiceGetMatchingServices(0, matching, &iterator); kr != 0 {
		return fmt.Errorf("IOServiceGetMatchingServices returned %d", kr)
	}

	found := false
	seen := 0
	for {
		service := ioIteratorNext(iterator)
		if service == 0 {
			break
		}
		seen++

		usagePage, _ := propInt(service, "PrimaryUsagePage")
		usage, _ := propInt(service, "PrimaryUsage")
		debugf("hid_service service=%d usage_page=%d usage=%d", service, usagePage, usage)
		if usagePage != PageVendor || usage != UsageAccel {
			ioObjectRelease(service)
			continue
		}

		hid := ioHIDDeviceCreate(kCFAllocatorDefault, service)
		openResult := int32(-1)
		if hid != 0 {
			openResult = ioHIDDeviceOpen(hid, 0)
		}
		debugf("hid_match service=%d hid=%d open_result=%d", service, hid, openResult)
		if hid != 0 && openResult == 0 {
			reportBuf := make([]byte, ReportBufSize)
			globalStreamState.reportBuf = append(globalStreamState.reportBuf, reportBuf)
			ioHIDDeviceRegisterInputReport(
				hid,
				uintptr(unsafe.Pointer(&reportBuf[0])),
				ReportBufSize,
				accelCallbackPtr,
				0,
			)
			ioHIDDeviceScheduleWithRL(hid, cfRunLoopGetCurrent(), kCFRunLoopDefaultMode)
			found = true
		}
		ioObjectRelease(service)
	}
	if !found {
		return fmt.Errorf("no accelerometer HID device found (enumerated %d AppleSPUHIDDevice services)", seen)
	}
	debugf("accelerometer_registration_success seen=%d", seen)
	return nil
}

func derefSymbol(lib uintptr, name string) uintptr {
	sym, _ := purego.Dlsym(lib, name)
	if sym == 0 {
		return 0
	}
	return **(**uintptr)(unsafe.Pointer(&sym))
}

func cfStr(s string) uintptr {
	return cfStringCreateWithCString(0, cStr(s), CFStringEncodingUTF8)
}

func cfNum32(v int32) uintptr {
	return cfNumberCreate(0, CFNumberSInt32Type, uintptr(unsafe.Pointer(&v)))
}

func cStr(s string) *byte {
	b := make([]byte, len(s)+1)
	copy(b, s)
	return &b[0]
}

func propInt(service uint32, key string) (int64, bool) {
	ref := ioRegistryEntryCreateCFProp(service, cfStr(key), 0, 0)
	if ref == 0 {
		return 0, false
	}
	var val int64
	if !cfNumberGetValue(ref, CFNumberSInt64Type, uintptr(unsafe.Pointer(&val))) {
		return 0, false
	}
	return val, true
}

func parseIMUReport(data []byte) (x, y, z int32) {
	if len(data) < IMUDataOffset+12 {
		return 0, 0, 0
	}
	offset := IMUDataOffset
	x = int32(binary.LittleEndian.Uint32(data[offset:]))
	y = int32(binary.LittleEndian.Uint32(data[offset+4:]))
	z = int32(binary.LittleEndian.Uint32(data[offset+8:]))
	return x, y, z
}
