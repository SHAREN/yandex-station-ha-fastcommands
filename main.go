package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
	"unicode"
)

const (
	defaultAlicedAddr = "127.0.0.1:9875"
	defaultLogFile    = "/data/opt/alice-ha-fastcommands/fastcommands.log"
	maxFrameSize      = 10 << 20
)

var version = "dev"

type Config struct {
	Station            string   `json:"station"`
	AlicedAddr         string   `json:"aliced_addr"`
	WebhookURL         string   `json:"webhook_url"`
	CancelNativeDialog *bool    `json:"cancel_native_dialog,omitempty"`
	DebounceMS         int      `json:"debounce_ms"`
	AllowedCommands    []string `json:"allowed_commands"`
	LogFile            string   `json:"log_file"`
}

type commandEvent struct {
	Source     string
	Transcript string
}

type webhookPayload struct {
	Station   string `json:"station"`
	Command   string `json:"command"`
	Source    string `json:"source"`
	Timestamp string `json:"timestamp"`
}

type bridge struct {
	cfg     Config
	client  *http.Client
	allowed map[string]struct{}
	last    map[string]time.Time
}

func main() {
	configPath := flag.String("config", "/data/opt/alice-ha-fastcommands/config.json", "path to configuration JSON")
	probe := flag.Bool("probe", false, "verify that the local aliced IPC endpoint is reachable")
	selfTest := flag.Bool("self-test", false, "run a local decoder self-test and exit")
	showVersion := flag.Bool("version", false, "print version and exit")
	flag.Parse()

	if *showVersion {
		fmt.Println(version)
		return
	}
	if *selfTest {
		if err := runSelfTest(); err != nil {
			log.Fatal(err)
		}
		fmt.Println("self-test: ok")
		return
	}

	cfg, err := loadConfig(*configPath)
	if err != nil {
		log.Fatal(err)
	}

	if *probe {
		conn, err := net.DialTimeout("tcp", cfg.AlicedAddr, 2*time.Second)
		if err != nil {
			log.Fatalf("probe aliced %s: %v", cfg.AlicedAddr, err)
		}
		_ = conn.Close()
		fmt.Printf("probe: aliced reachable at %s\n", cfg.AlicedAddr)
		return
	}

	logFile, err := os.OpenFile(cfg.LogFile, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		log.Fatalf("open log file: %v", err)
	}
	defer logFile.Close()
	log.SetOutput(logFile)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	b := newBridge(cfg)
	log.Printf("start version=%s station=%q aliced=%s commands=%d", version, cfg.Station, cfg.AlicedAddr, len(b.allowed))
	if err := b.run(ctx); err != nil && !errors.Is(err, context.Canceled) {
		log.Fatal(err)
	}
}

func loadConfig(path string) (Config, error) {
	var cfg Config
	raw, err := os.ReadFile(path)
	if err != nil {
		return cfg, fmt.Errorf("read config: %w", err)
	}
	if err := json.Unmarshal(raw, &cfg); err != nil {
		return cfg, fmt.Errorf("decode config: %w", err)
	}

	if strings.TrimSpace(cfg.Station) == "" {
		cfg.Station = "Yandex Station"
	}
	if strings.TrimSpace(cfg.AlicedAddr) == "" {
		cfg.AlicedAddr = defaultAlicedAddr
	}
	if strings.TrimSpace(cfg.LogFile) == "" {
		cfg.LogFile = defaultLogFile
	}
	if cfg.DebounceMS <= 0 {
		cfg.DebounceMS = 1200
	}
	if cfg.DebounceMS > 60_000 {
		return cfg, fmt.Errorf("debounce_ms must be <= 60000")
	}
	if len(cfg.AllowedCommands) == 0 {
		cfg.AllowedCommands = []string{"включи свет", "выключи свет"}
	}
	if cfg.CancelNativeDialog == nil {
		value := true
		cfg.CancelNativeDialog = &value
	}

	if err := validateLoopback(cfg.AlicedAddr); err != nil {
		return cfg, err
	}
	if err := validateWebhookURL(cfg.WebhookURL); err != nil {
		return cfg, err
	}

	seen := map[string]struct{}{}
	for _, phrase := range cfg.AllowedCommands {
		n := normalizePhrase(phrase)
		if n == "" {
			return cfg, fmt.Errorf("allowed_commands contains an empty phrase")
		}
		seen[n] = struct{}{}
	}
	if len(seen) == 0 {
		return cfg, fmt.Errorf("allowed_commands must not be empty")
	}

	return cfg, nil
}

func validateLoopback(addr string) error {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return fmt.Errorf("bad aliced_addr: %w", err)
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		return fmt.Errorf("aliced_addr must point to a loopback address, got %q", addr)
	}
	return nil
}

func validateWebhookURL(raw string) error {
	if strings.TrimSpace(raw) == "" {
		return fmt.Errorf("webhook_url is required")
	}
	u, err := url.Parse(raw)
	if err != nil {
		return fmt.Errorf("bad webhook_url: %w", err)
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return fmt.Errorf("webhook_url must use http or https")
	}
	if u.Host == "" {
		return fmt.Errorf("webhook_url must include a host")
	}
	if u.User != nil {
		return fmt.Errorf("webhook_url must not embed credentials")
	}
	if !strings.HasPrefix(u.Path, "/api/webhook/") || strings.TrimPrefix(u.Path, "/api/webhook/") == "" {
		return fmt.Errorf("webhook_url must point to Home Assistant /api/webhook/<id>")
	}
	if u.RawQuery != "" || u.Fragment != "" {
		return fmt.Errorf("webhook_url must not contain query parameters or a fragment")
	}
	return nil
}

func newBridge(cfg Config) *bridge {
	allowed := make(map[string]struct{}, len(cfg.AllowedCommands))
	for _, phrase := range cfg.AllowedCommands {
		allowed[normalizePhrase(phrase)] = struct{}{}
	}
	return &bridge{
		cfg:     cfg,
		client:  &http.Client{Timeout: 2500 * time.Millisecond},
		allowed: allowed,
		last:    make(map[string]time.Time),
	}
}

func (b *bridge) run(ctx context.Context) error {
	for {
		if err := ctx.Err(); err != nil {
			return err
		}

		conn, err := (&net.Dialer{Timeout: 2 * time.Second}).DialContext(ctx, "tcp", b.cfg.AlicedAddr)
		if err != nil {
			log.Printf("aliced connect failed: %v", err)
			if !sleepContext(ctx, 500*time.Millisecond) {
				return ctx.Err()
			}
			continue
		}

		log.Printf("aliced connected")
		err = b.readLoop(ctx, conn)
		_ = conn.Close()
		if err != nil && !errors.Is(err, context.Canceled) {
			log.Printf("aliced stream ended: %v", err)
		}
		if !sleepContext(ctx, 300*time.Millisecond) {
			return ctx.Err()
		}
	}
}

func (b *bridge) readLoop(ctx context.Context, conn net.Conn) error {
	r := bufio.NewReaderSize(conn, 64*1024)
	for {
		if err := ctx.Err(); err != nil {
			return err
		}

		_ = conn.SetReadDeadline(time.Now().Add(65 * time.Second))
		payload, err := readIPCFrame(r)
		if err != nil {
			if ne, ok := err.(net.Error); ok && ne.Timeout() {
				continue
			}
			return err
		}

		event, ok, err := decodeCommandEvent(payload)
		if err != nil {
			log.Printf("ignore malformed IPC event: %v", err)
			continue
		}
		if !ok || event.Source != "command" {
			continue
		}

		command := normalizePhrase(event.Transcript)
		if _, ok := b.allowed[command]; !ok {
			continue
		}
		b.handleCommand(ctx, command)
	}
}

func (b *bridge) handleCommand(ctx context.Context, command string) {
	now := time.Now()
	if previous := b.last[command]; !previous.IsZero() && now.Sub(previous) < time.Duration(b.cfg.DebounceMS)*time.Millisecond {
		log.Printf("duplicate ignored command=%q", command)
		return
	}
	b.last[command] = now

	if b.cfg.CancelNativeDialog != nil && *b.cfg.CancelNativeDialog {
		if err := sendCancelDialog(b.cfg.AlicedAddr); err != nil {
			log.Printf("cancel native dialog failed command=%q: %v", command, err)
		}
	}

	body, _ := json.Marshal(webhookPayload{
		Station:   b.cfg.Station,
		Command:   command,
		Source:    "command",
		Timestamp: time.Now().UTC().Format(time.RFC3339Nano),
	})

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, b.cfg.WebhookURL, bytes.NewReader(body))
	if err != nil {
		log.Printf("build webhook request failed command=%q: %v", command, err)
		return
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "alice-ha-fastcommands/"+version)

	resp, err := b.client.Do(req)
	if err != nil {
		log.Printf("HA webhook failed command=%q: %v", command, err)
		return
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 2048))
	_ = resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		log.Printf("HA webhook command=%q status=%s", command, resp.Status)
		return
	}
	log.Printf("HA webhook ok command=%q", command)
}

func readIPCFrame(r io.Reader) ([]byte, error) {
	var header [4]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return nil, err
	}
	length := int32(binary.LittleEndian.Uint32(header[:]))
	if length < 0 || length > maxFrameSize {
		return nil, fmt.Errorf("invalid IPC frame length %d", length)
	}
	payload := make([]byte, int(length))
	if _, err := io.ReadFull(r, payload); err != nil {
		return nil, err
	}
	return payload, nil
}

func writeIPCFrame(w io.Writer, payload []byte) error {
	if len(payload) > maxFrameSize {
		return fmt.Errorf("IPC frame too large")
	}
	var header [4]byte
	binary.LittleEndian.PutUint32(header[:], uint32(len(payload)))
	if _, err := w.Write(header[:]); err != nil {
		return err
	}
	_, err := w.Write(payload)
	return err
}

func decodeCommandEvent(message []byte) (commandEvent, bool, error) {
	message, err := unwrapIPCEnvelope(message)
	if err != nil {
		return commandEvent{}, false, err
	}

	state, ok, err := bytesField(message, 3)
	if err != nil || !ok {
		return commandEvent{}, false, err
	}

	sourceMessage, ok, err := bytesField(state, 10)
	if err != nil || !ok {
		return commandEvent{}, false, err
	}
	source, ok, err := stringField(sourceMessage, 6)
	if err != nil || !ok || source != "command" {
		return commandEvent{}, false, err
	}

	request, ok, err := bytesField(state, 15)
	if err != nil || !ok {
		return commandEvent{}, false, err
	}
	active, ok, err := varintField(request, 2)
	if err != nil || !ok || active == 0 {
		return commandEvent{}, false, err
	}
	transcript, ok, err := stringField(request, 1)
	if err != nil || !ok || strings.TrimSpace(transcript) == "" {
		return commandEvent{}, false, err
	}

	return commandEvent{Source: "command", Transcript: transcript}, true, nil
}

func unwrapIPCEnvelope(message []byte) ([]byte, error) {
	kind, kindOK, err := varintField(message, 253)
	if err != nil {
		return nil, err
	}
	body, bodyOK, err := bytesField(message, 252)
	if err != nil {
		return nil, err
	}
	if !kindOK || !bodyOK {
		return message, nil
	}

	var out []byte
	out = appendKey(out, kind, 2)
	out = appendVarint(out, uint64(len(body)))
	out = append(out, body...)
	return out, nil
}

func sendCancelDialog(alicedAddr string) error {
	var method []byte
	method = appendKey(method, 1, 0)
	method = appendVarint(method, 3)

	var remoting []byte
	remoting = appendBytesField(remoting, 7, []byte("AliceCapability"))
	remoting = appendBytesField(remoting, 8, method)

	var message []byte
	message = appendBytesField(message, 252, remoting)
	message = appendKey(message, 253, 0)
	message = appendVarint(message, 210)

	conn, err := net.DialTimeout("tcp", alicedAddr, 1200*time.Millisecond)
	if err != nil {
		return err
	}
	defer conn.Close()
	_ = conn.SetWriteDeadline(time.Now().Add(1200 * time.Millisecond))
	return writeIPCFrame(conn, message)
}

func bytesField(data []byte, wanted uint64) ([]byte, bool, error) {
	var result []byte
	found := false
	err := walkProtoFields(data, func(number, wire uint64, raw []byte, value uint64) bool {
		if number == wanted && wire == 2 {
			result = append([]byte(nil), raw...)
			found = true
			return false
		}
		return true
	})
	return result, found, err
}

func stringField(data []byte, wanted uint64) (string, bool, error) {
	raw, ok, err := bytesField(data, wanted)
	if err != nil || !ok {
		return "", ok, err
	}
	return string(raw), true, nil
}

func varintField(data []byte, wanted uint64) (uint64, bool, error) {
	var result uint64
	found := false
	err := walkProtoFields(data, func(number, wire uint64, raw []byte, value uint64) bool {
		if number == wanted && wire == 0 {
			result = value
			found = true
			return false
		}
		return true
	})
	return result, found, err
}

func walkProtoFields(data []byte, visit func(number, wire uint64, raw []byte, value uint64) bool) error {
	for offset := 0; offset < len(data); {
		key, err := consumeVarint(data, &offset)
		if err != nil {
			return err
		}
		number := key >> 3
		wire := key & 7
		if number == 0 {
			return fmt.Errorf("invalid protobuf field number 0")
		}

		switch wire {
		case 0:
			value, err := consumeVarint(data, &offset)
			if err != nil {
				return err
			}
			if !visit(number, wire, nil, value) {
				return nil
			}
		case 1:
			if offset+8 > len(data) {
				return io.ErrUnexpectedEOF
			}
			raw := data[offset : offset+8]
			offset += 8
			if !visit(number, wire, raw, 0) {
				return nil
			}
		case 2:
			length, err := consumeVarint(data, &offset)
			if err != nil {
				return err
			}
			if length > uint64(len(data)-offset) {
				return io.ErrUnexpectedEOF
			}
			raw := data[offset : offset+int(length)]
			offset += int(length)
			if !visit(number, wire, raw, 0) {
				return nil
			}
		case 5:
			if offset+4 > len(data) {
				return io.ErrUnexpectedEOF
			}
			raw := data[offset : offset+4]
			offset += 4
			if !visit(number, wire, raw, 0) {
				return nil
			}
		default:
			return fmt.Errorf("unsupported protobuf wire type %d", wire)
		}
	}
	return nil
}

func consumeVarint(data []byte, offset *int) (uint64, error) {
	var value uint64
	for shift := uint(0); shift < 64; shift += 7 {
		if *offset >= len(data) {
			return 0, io.ErrUnexpectedEOF
		}
		b := data[*offset]
		*offset = *offset + 1
		value |= uint64(b&0x7f) << shift
		if b&0x80 == 0 {
			return value, nil
		}
	}
	return 0, fmt.Errorf("invalid protobuf varint")
}

func appendKey(out []byte, field, wire uint64) []byte {
	return appendVarint(out, field<<3|wire)
}

func appendVarint(out []byte, value uint64) []byte {
	for value >= 0x80 {
		out = append(out, byte(value&0x7f)|0x80)
		value >>= 7
	}
	return append(out, byte(value))
}

func appendBytesField(out []byte, field uint64, value []byte) []byte {
	out = appendKey(out, field, 2)
	out = appendVarint(out, uint64(len(value)))
	return append(out, value...)
}

func normalizePhrase(s string) string {
	s = strings.ReplaceAll(strings.ToLower(s), "ё", "е")
	parts := strings.FieldsFunc(s, func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsDigit(r)
	})
	return strings.Join(parts, " ")
}

func sleepContext(ctx context.Context, d time.Duration) bool {
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

func runSelfTest() error {
	for _, phrase := range []string{"включи свет", "выключи свет"} {
		message := syntheticCommandMessage(phrase, "command", 1)
		event, ok, err := decodeCommandEvent(message)
		if err != nil {
			return err
		}
		if !ok || event.Source != "command" || event.Transcript != phrase {
			return fmt.Errorf("decode mismatch: ok=%v event=%+v", ok, event)
		}
	}
	if _, ok, err := decodeCommandEvent(syntheticCommandMessage("включи свет", "voice", 1)); err != nil || ok {
		return fmt.Errorf("voice event must not be accepted")
	}
	return nil
}

func syntheticCommandMessage(phrase, source string, active uint64) []byte {
	var sourceMessage []byte
	sourceMessage = appendBytesField(sourceMessage, 6, []byte(source))
	var request []byte
	request = appendBytesField(request, 1, []byte(phrase))
	request = appendKey(request, 2, 0)
	request = appendVarint(request, active)
	var state []byte
	state = appendBytesField(state, 10, sourceMessage)
	state = appendBytesField(state, 15, request)
	var message []byte
	message = appendBytesField(message, 3, state)
	return message
}
