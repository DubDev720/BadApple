package sensor

type CandidateDetector struct {
	detector *Detector
}

func NewCandidateDetector() *CandidateDetector {
	return &CandidateDetector{detector: NewDetector()}
}

func (d *CandidateDetector) ProcessSample(x, y, z, tNow float64) *SlapEvent {
	d.detector.Process(x, y, z, tNow)
	if len(d.detector.Events) == 0 {
		return nil
	}
	ev := d.detector.Events[len(d.detector.Events)-1]
	return &SlapEvent{
		Amplitude: ev.Amplitude,
		Severity:  ev.Severity,
		Timestamp: ev.Time,
	}
}

func (d *CandidateDetector) SampleRate() int {
	return d.detector.FS
}
