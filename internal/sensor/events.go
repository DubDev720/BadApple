package sensor

import "time"

type SlapEvent struct {
	Amplitude float64
	Severity  string
	Timestamp time.Time
}
