package media

import "testing"

func TestValidateClipAcceptsMinimalWAV(t *testing.T) {
	clip := Clip{Name: "ok.wav"}
	data := []byte{
		'R', 'I', 'F', 'F',
		0x28, 0x00, 0x00, 0x00,
		'W', 'A', 'V', 'E',
		'f', 'm', 't', ' ',
		0x10, 0x00, 0x00, 0x00,
		0x01, 0x00, 0x02, 0x00,
		0x80, 0xbb, 0x00, 0x00,
		0x00, 0xee, 0x02, 0x00,
		0x04, 0x00, 0x10, 0x00,
		'd', 'a', 't', 'a',
		0x04, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x00,
	}

	if err := ValidateClip(clip, data); err != nil {
		t.Fatalf("ValidateClip returned error: %v", err)
	}
}

func TestValidateClipRejectsBadHeader(t *testing.T) {
	clip := Clip{Name: "bad.wav"}
	data := make([]byte, 44)
	copy(data, []byte("NOPE"))

	if err := ValidateClip(clip, data); err == nil {
		t.Fatal("ValidateClip succeeded for bad header")
	}
}

func TestValidateClipRejectsNonCanonicalSampleRate(t *testing.T) {
	clip := Clip{Name: "bad-rate.wav"}
	data := []byte{
		'R', 'I', 'F', 'F',
		0x28, 0x00, 0x00, 0x00,
		'W', 'A', 'V', 'E',
		'f', 'm', 't', ' ',
		0x10, 0x00, 0x00, 0x00,
		0x01, 0x00, 0x02, 0x00,
		0x44, 0xac, 0x00, 0x00,
		0x10, 0xb1, 0x02, 0x00,
		0x04, 0x00, 0x10, 0x00,
		'd', 'a', 't', 'a',
		0x04, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x00,
	}

	if err := ValidateClip(clip, data); err == nil {
		t.Fatal("ValidateClip accepted a non-canonical sample rate")
	}
}

func TestValidateRuntimePackName(t *testing.T) {
	if err := ValidateRuntimePackName("afterglow"); err != nil {
		t.Fatalf("expected valid runtime pack name, got %v", err)
	}
	for _, name := range []string{"", "sexy", "pain", "bad apple", "1bad"} {
		if err := ValidateRuntimePackName(name); err == nil {
			t.Fatalf("expected invalid runtime pack name %q to fail", name)
		}
	}
}

func TestSupportedImportFiles(t *testing.T) {
	for _, name := range []string{"clip.wav", "clip.mp3", "clip.m4a", "clip.aiff", "clip.caf"} {
		if !IsSupportedImportFile(name) {
			t.Fatalf("expected %q to be supported", name)
		}
	}
	for _, name := range []string{"clip.txt", "clip", "clip.png"} {
		if IsSupportedImportFile(name) {
			t.Fatalf("expected %q to be rejected", name)
		}
	}
}
