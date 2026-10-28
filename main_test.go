package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestNormalizePhrase(t *testing.T) {
	got := normalizePhrase("  ВКЛЮЧИ,   СВЁТ! ")
	if got != "включи свет" {
		t.Fatalf("got %q", got)
	}
}

func TestDecodeCommandEvent(t *testing.T) {
	msg := syntheticCommandMessage("включи свет", "command", 1)
	event, ok, err := decodeCommandEvent(msg)
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Fatal("expected command event")
	}
	if event.Source != "command" || event.Transcript != "включи свет" {
		t.Fatalf("unexpected event: %+v", event)
	}
}

func TestRejectsVoiceEvent(t *testing.T) {
	msg := syntheticCommandMessage("включи свет", "voice", 1)
	_, ok, err := decodeCommandEvent(msg)
	if err != nil {
		t.Fatal(err)
	}
	if ok {
		t.Fatal("voice event must not be accepted")
	}
}

func TestRejectsInactiveCommand(t *testing.T) {
	msg := syntheticCommandMessage("включи свет", "command", 0)
	_, ok, err := decodeCommandEvent(msg)
	if err != nil {
		t.Fatal(err)
	}
	if ok {
		t.Fatal("inactive command must not be accepted")
	}
}

func TestLoadConfigDefaults(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.json")
	if err := os.WriteFile(path, []byte(`{"webhook_url":"http://homeassistant.local:8123/api/webhook/test"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg, err := loadConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.AlicedAddr != defaultAlicedAddr {
		t.Fatalf("unexpected aliced_addr: %s", cfg.AlicedAddr)
	}
	if cfg.DebounceMS != 1200 {
		t.Fatalf("unexpected debounce: %d", cfg.DebounceMS)
	}
	if len(cfg.AllowedCommands) != 2 {
		t.Fatalf("unexpected commands: %#v", cfg.AllowedCommands)
	}
	if cfg.CancelNativeDialog == nil || !*cfg.CancelNativeDialog {
		t.Fatal("cancel_native_dialog should default to true")
	}
}

func TestWebhookValidation(t *testing.T) {
	valid := []string{
		"http://192.168.1.10:8123/api/webhook/abc",
		"http://homeassistant.local:8123/api/webhook/abc",
		"https://ha.example.net/api/webhook/abc",
	}
	for _, raw := range valid {
		if err := validateWebhookURL(raw); err != nil {
			t.Fatalf("valid URL %q rejected: %v", raw, err)
		}
	}

	invalid := []string{
		"",
		"ftp://homeassistant.local/api/webhook/abc",
		"http://homeassistant.local:8123/api/states/light.test",
		"http://user:pass@homeassistant.local:8123/api/webhook/abc",
		"http://homeassistant.local:8123/api/webhook/abc?x=1",
	}
	for _, raw := range invalid {
		if err := validateWebhookURL(raw); err == nil {
			t.Fatalf("invalid URL %q accepted", raw)
		}
	}
}
