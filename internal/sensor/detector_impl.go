package sensor

import (
	"math"
	"time"
)

const SampleRate = 100

type Event struct {
	Time      time.Time
	Severity  string
	Symbol    string
	Label     string
	Amplitude float64
	Sources   []string
	Bands     []string
}

type Detector struct {
	SampleCount int
	FS          int

	LatestRaw [3]float64
	LatestMag float64

	hpAlpha   float64
	hpPrevRaw [3]float64
	hpPrevOut [3]float64
	hpReady   bool

	Waveform    *RingFloat
	WaveformXYZ *RingVec3

	sta          [3]float64
	lta          [3]float64
	staN         [3]int
	ltaN         [3]int
	staLTAOn     [3]float64
	staLTAOff    [3]float64
	STALTAActive [3]bool
	STALTALatest [3]float64
	STALTARings  [3]*RingFloat

	cusumPos float64
	cusumNeg float64
	cusumMu  float64
	cusumK   float64
	cusumH   float64
	CUSUMVal float64

	kurtBuf  *RingFloat
	Kurtosis float64

	peakBuf  *RingFloat
	Crest    float64
	RMS      float64
	Peak     float64
	MADSigma float64

	RMSTrend  *RingFloat
	rmsWindow *RingFloat

	Events   []Event
	lastEvtT float64

	GyroLatest [3]float64

	Q          [4]float64
	mahonyKP   float64
	mahonyKI   float64
	mahonyErrI [3]float64
	orientInit bool

	hrHPAlpha   float64
	hrLPAlpha   float64
	hrHPPrevIn  float64
	hrHPPrevOut float64
	hrLPPrev    float64
	hrBuf       *RingFloat
	HRBPM       float64
	HRConf      float64
	HRValid     bool

	Period      float64
	PeriodFreq  float64
	PeriodCV    float64
	PeriodSTD   float64
	PeriodValid bool
	ACorrRing   []float64

	staDec  int
	kurtDec int
	rmsDec  int
}

func NewDetector() *Detector {
	fs := SampleRate
	n5 := fs * 5
	d := &Detector{
		FS:          fs,
		hpAlpha:     0.95,
		Waveform:    NewRingFloat(n5),
		WaveformXYZ: NewRingVec3(n5),
		staN:        [3]int{3, 15, 50},
		ltaN:        [3]int{100, 500, 2000},
		staLTAOn:    [3]float64{3.0, 2.5, 2.0},
		staLTAOff:   [3]float64{1.5, 1.3, 1.2},
		cusumK:      0.0005,
		cusumH:      0.01,
		kurtBuf:     NewRingFloat(100),
		Kurtosis:    3.0,
		peakBuf:     NewRingFloat(200),
		Crest:       1.0,
		RMSTrend:    NewRingFloat(100),
		rmsWindow:   NewRingFloat(fs),
		Q:           [4]float64{1, 0, 0, 0},
		mahonyKP:    1.0,
		mahonyKI:    0.05,
		hrHPAlpha:   float64(fs) / (float64(fs) + 2.0*math.Pi*0.8),
		hrLPAlpha:   2.0 * math.Pi * 3.0 / (2.0*math.Pi*3.0 + float64(fs)),
		hrBuf:       NewRingFloat(fs * 10),
	}
	for i := range 3 {
		d.lta[i] = 1e-10
		d.STALTALatest[i] = 1.0
		d.STALTARings[i] = NewRingFloat(30)
	}
	return d
}

func (d *Detector) Process(ax, ay, az, tNow float64) float64 {
	d.SampleCount++
	d.LatestRaw = [3]float64{ax, ay, az}
	d.LatestMag = math.Sqrt(ax*ax + ay*ay + az*az)
	d.updateOrientation(ax, ay, az)

	if !d.hpReady {
		d.hpPrevRaw = [3]float64{ax, ay, az}
		d.hpReady = true
		d.Waveform.Push(0)
		return 0
	}

	a := d.hpAlpha
	hx := a * (d.hpPrevOut[0] + ax - d.hpPrevRaw[0])
	hy := a * (d.hpPrevOut[1] + ay - d.hpPrevRaw[1])
	hz := a * (d.hpPrevOut[2] + az - d.hpPrevRaw[2])
	d.hpPrevRaw = [3]float64{ax, ay, az}
	d.hpPrevOut = [3]float64{hx, hy, hz}
	mag := math.Sqrt(hx*hx + hy*hy + hz*hz)

	d.Waveform.Push(mag)
	d.WaveformXYZ.Push3(hx, hy, hz)

	hpOut := d.hrHPAlpha * (d.hrHPPrevOut + mag - d.hrHPPrevIn)
	d.hrHPPrevIn = mag
	d.hrHPPrevOut = hpOut
	lpOut := d.hrLPAlpha*hpOut + (1.0-d.hrLPAlpha)*d.hrLPPrev
	d.hrLPPrev = lpOut
	d.hrBuf.Push(lpOut)

	d.rmsWindow.Push(mag)
	d.rmsDec++
	if d.rmsDec >= maxInt(1, d.FS/10) {
		d.rmsDec = 0
		vals := d.rmsWindow.Slice()
		if len(vals) > 0 {
			var sumSquares float64
			for _, v := range vals {
				sumSquares += v * v
			}
			d.RMSTrend.Push(math.Sqrt(sumSquares / float64(len(vals))))
		}
	}

	var detections []detection
	e := mag * mag
	for i := range 3 {
		d.sta[i] += (e - d.sta[i]) / float64(d.staN[i])
		d.lta[i] += (e - d.lta[i]) / float64(d.ltaN[i])
		ratio := d.sta[i] / (d.lta[i] + 1e-30)
		d.STALTALatest[i] = ratio
		if ratio > d.staLTAOn[i] && !d.STALTAActive[i] {
			d.STALTAActive[i] = true
			detections = append(detections, detection{source: "STA/LTA"})
		} else if ratio < d.staLTAOff[i] {
			d.STALTAActive[i] = false
		}
	}
	d.staDec++
	if d.staDec >= maxInt(1, d.FS/30) {
		d.staDec = 0
		for i := range 3 {
			d.STALTARings[i].Push(d.STALTALatest[i])
		}
	}

	d.cusumMu += 0.0001 * (mag - d.cusumMu)
	d.cusumPos = math.Max(0, d.cusumPos+mag-d.cusumMu-d.cusumK)
	d.cusumNeg = math.Max(0, d.cusumNeg-mag+d.cusumMu-d.cusumK)
	d.CUSUMVal = math.Max(d.cusumPos, d.cusumNeg)
	if d.cusumPos > d.cusumH {
		detections = append(detections, detection{source: "CUSUM"})
		d.cusumPos = 0
	}
	if d.cusumNeg > d.cusumH {
		detections = append(detections, detection{source: "CUSUM"})
		d.cusumNeg = 0
	}

	d.kurtBuf.Push(mag)
	d.kurtDec++
	if d.kurtDec >= 10 && d.kurtBuf.Len() >= 50 {
		d.kurtDec = 0
		buf := d.kurtBuf.Slice()
		n := float64(len(buf))
		mu := sumFloat64(buf) / n
		var m2, m4 float64
		for _, v := range buf {
			diff := v - mu
			d2 := diff * diff
			m2 += d2
			m4 += d2 * d2
		}
		m2 /= n
		m4 /= n
		d.Kurtosis = m4 / (m2*m2 + 1e-30)
		if d.Kurtosis > 6 {
			detections = append(detections, detection{source: "KURTOSIS"})
		}
	}

	d.peakBuf.Push(mag)
	if d.peakBuf.Len() >= 50 && d.SampleCount%10 == 0 {
		buf := d.peakBuf.Slice()
		sorted := sortedCopy(buf)
		n := len(sorted)
		median := sorted[n/2]

		devs := make([]float64, n)
		for i, v := range sorted {
			devs[i] = math.Abs(v - median)
		}
		sortFloat64s(devs)
		mad := devs[n/2]
		sigma := 1.4826*mad + 1e-30
		d.MADSigma = sigma

		var sumSquares float64
		var peak float64
		for _, v := range buf {
			sumSquares += v * v
			if abs := math.Abs(v); abs > peak {
				peak = abs
			}
		}
		d.RMS = math.Sqrt(sumSquares / float64(n))
		d.Peak = peak
		d.Crest = peak / (d.RMS + 1e-30)

		if math.Abs(mag-median)/sigma > 2.0 {
			detections = append(detections, detection{source: "PEAK"})
		}
	}

	if len(detections) > 0 && (tNow-d.lastEvtT) > 0.01 {
		d.lastEvtT = tNow
		d.classify(detections, tNow, mag)
	}
	return mag
}

func (d *Detector) updateOrientation(ax, ay, az float64) {
	aNorm := math.Sqrt(ax*ax + ay*ay + az*az)
	if aNorm < 0.3 {
		return
	}
	gx := d.GyroLatest[0] * math.Pi / 180
	gy := d.GyroLatest[1] * math.Pi / 180
	gz := d.GyroLatest[2] * math.Pi / 180
	dt := 1.0 / float64(d.FS)

	if !d.orientInit {
		inv := 1.0 / aNorm
		axN, ayN, azN := ax*inv, ay*inv, az*inv
		pitch0 := math.Atan2(-axN, -azN)
		roll0 := math.Atan2(ayN, -azN)
		cp := math.Cos(pitch0 * 0.5)
		sp := math.Sin(pitch0 * 0.5)
		cr := math.Cos(roll0 * 0.5)
		sr := math.Sin(roll0 * 0.5)
		d.Q = [4]float64{cr * cp, sr * cp, cr * sp, -sr * sp}
		d.orientInit = true
		return
	}

	qw, qx, qy, qz := d.Q[0], d.Q[1], d.Q[2], d.Q[3]
	inv := 1.0 / aNorm
	axN, ayN, azN := ax*inv, ay*inv, az*inv
	vx := 2.0 * (qx*qz - qw*qy)
	vy := 2.0 * (qw*qx + qy*qz)
	vz := qw*qw - qx*qx - qy*qy + qz*qz
	ex := ayN*(-vz) - azN*(-vy)
	ey := azN*(-vx) - axN*(-vz)
	ez := axN*(-vy) - ayN*(-vx)

	d.mahonyErrI[0] += d.mahonyKI * ex * dt
	d.mahonyErrI[1] += d.mahonyKI * ey * dt
	d.mahonyErrI[2] += d.mahonyKI * ez * dt
	gx += d.mahonyKP*ex + d.mahonyErrI[0]
	gy += d.mahonyKP*ey + d.mahonyErrI[1]
	gz += d.mahonyKP*ez + d.mahonyErrI[2]

	hdt := 0.5 * dt
	dw := (-qx*gx - qy*gy - qz*gz) * hdt
	dx := (qw*gx + qy*gz - qz*gy) * hdt
	dy := (qw*gy - qx*gz + qz*gx) * hdt
	dz := (qw*gz + qx*gy - qy*gx) * hdt
	qw += dw
	qx += dx
	qy += dy
	qz += dz

	n := math.Sqrt(qw*qw + qx*qx + qy*qy + qz*qz)
	if n > 0 {
		inv := 1.0 / n
		qw *= inv
		qx *= inv
		qy *= inv
		qz *= inv
	}
	d.Q = [4]float64{qw, qx, qy, qz}
}

type detection struct {
	source string
}

func (d *Detector) classify(dets []detection, t, amp float64) {
	sources := make(map[string]bool)
	for _, det := range dets {
		sources[det.source] = true
	}
	ns := len(sources)
	var sev, sym, lbl string
	switch {
	case ns >= 4 && amp > 0.05:
		sev, sym, lbl = "CHOC_MAJEUR", "★", "MAJOR"
	case ns >= 3 && amp > 0.02:
		sev, sym, lbl = "CHOC_MOYEN", "▲", "shock"
	case sources["PEAK"] && amp > 0.005:
		sev, sym, lbl = "MICRO_CHOC", "△", "micro-choc"
	case (sources["STA/LTA"] || sources["CUSUM"]) && amp > 0.003:
		sev, sym, lbl = "VIBRATION", "●", "vibration"
	case amp > 0.001:
		sev, sym, lbl = "VIB_LEGERE", "○", "light-vib"
	default:
		sev, sym, lbl = "MICRO_VIB", "·", "micro-vib"
	}

	sourceList := make([]string, 0, len(sources))
	for source := range sources {
		sourceList = append(sourceList, source)
	}
	ev := Event{
		Time:      time.Unix(int64(t), int64((t-math.Floor(t))*1e9)),
		Severity:  sev,
		Symbol:    sym,
		Label:     lbl,
		Amplitude: amp,
		Sources:   sourceList,
	}
	d.Events = append(d.Events, ev)
	if len(d.Events) > 500 {
		d.Events = d.Events[len(d.Events)-500:]
	}
}

func sumFloat64(values []float64) float64 {
	var total float64
	for _, v := range values {
		total += v
	}
	return total
}

func sortedCopy(values []float64) []float64 {
	out := make([]float64, len(values))
	copy(out, values)
	sortFloat64s(out)
	return out
}

func sortFloat64s(values []float64) {
	for i := 1; i < len(values); i++ {
		key := values[i]
		j := i - 1
		for j >= 0 && values[j] > key {
			values[j+1] = values[j]
			j--
		}
		values[j+1] = key
	}
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}
