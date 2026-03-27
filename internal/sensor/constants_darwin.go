//go:build darwin

package sensor

const (
	PageVendor = 0xFF00
	UsageAccel = 3

	IMUReportLen     = 22
	IMUDecimation    = 8
	IMUDataOffset    = 6
	ReportBufSize    = 4096
	ReportIntervalUS = 1000
	AccelScale       = 65536.0

	CFStringEncodingUTF8 = 0x08000100
	CFNumberSInt32Type   = 3
	CFNumberSInt64Type   = 4
)
