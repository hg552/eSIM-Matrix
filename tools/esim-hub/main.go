package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"embed"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"sync"
	"time"
)

var (
	errNoNativeClipboard = errors.New("native clipboard is only available on Windows")
	errNoNativeGUI       = errors.New("native window is only available on Windows")
)

//go:embed web/*
var embeddedWeb embed.FS

const (
	defaultListenAddr = "0.0.0.0:9787"
	defaultPort       = 9787
	maxHistoryItems   = 500
	maxChatItems      = 200
)

type FanoutTarget struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Type     string `json:"type"` // feishu | dingtalk | wecom | bark | discord | webhook | command
	Endpoint string `json:"endpoint"`
	Secret   string `json:"secret,omitempty"`
	Enabled  bool   `json:"enabled"`
	OnlyOTP  bool   `json:"onlyOtp"`
}

type HubConfig struct {
	ListenAddr      string         `json:"listenAddr"`
	WebhookToken    string         `json:"webhookToken"`
	RequireAuth     bool           `json:"requireAuth"`
	PhoneGatewayURL string         `json:"phoneGatewayUrl"`
	PhoneApiToken   string         `json:"phoneApiToken"`
	AutoCopyOTP     bool           `json:"autoCopyOtp"`
	DesktopNotify   bool           `json:"desktopNotify"`
	SoundAlert      bool           `json:"soundAlert"`
	AutoOpenBrowser bool           `json:"autoOpenBrowser"`
	ADBPath         string         `json:"adbPath,omitempty"`
	PreferredADBDev string         `json:"preferredAdbDevice,omitempty"`
	FanoutTargets   []FanoutTarget `json:"fanoutTargets"`
}

type WebhookEvent struct {
	ID                    string          `json:"id"`
	Event                 string          `json:"event"`
	MessageID             string          `json:"messageId,omitempty"`
	Sender                string          `json:"sender,omitempty"`
	Caller                string          `json:"caller,omitempty"`
	Body                  string          `json:"body,omitempty"`
	Text                  string          `json:"text,omitempty"`
	OTP                   string          `json:"otp,omitempty"`
	SlotIndex             *int            `json:"slotIndex,omitempty"`
	SubscriptionID        *int            `json:"subscriptionId,omitempty"`
	CarrierName           string          `json:"carrierName,omitempty"`
	ReceivedAtEpochMillis int64           `json:"receivedAtEpochMillis"`
	GatewayPort           int             `json:"gatewayPort,omitempty"`
	GatewayAddress        string          `json:"gatewayAddress,omitempty"`
	GatewayAddresses      []string        `json:"gatewayAddresses,omitempty"`
	ReplyMarkup           json.RawMessage `json:"reply_markup,omitempty"`
	RemoteIP              string          `json:"remoteIp,omitempty"`
}

type BotButton struct {
	Text         string `json:"text"`
	CallbackData string `json:"callback_data"`
}

type BotReplyMarkup struct {
	InlineKeyboard [][]BotButton `json:"inline_keyboard"`
}

type ChatEntry struct {
	ID        string        `json:"id"`
	Role      string        `json:"role"` // "user" | "bot" | "event"
	Text      string        `json:"text"`
	Keyboard  [][]BotButton `json:"keyboard,omitempty"`
	Timestamp int64         `json:"timestamp"`
}

type PendingCommand struct {
	ID           string `json:"id"`
	Text         string `json:"text,omitempty"`
	CallbackData string `json:"callbackData,omitempty"`
	CreatedAt    int64  `json:"createdAt"`
}

type PersistedState struct {
	Config  HubConfig      `json:"config"`
	Events  []WebhookEvent `json:"events"`
	ChatLog []ChatEntry    `json:"chatLog"`
}

type otpWaiter struct {
	senderContains string
	ch             chan WebhookEvent
}

type readyWaiter struct {
	ch chan WebhookEvent
}

type HubServer struct {
	mu              sync.RWMutex
	saveMu          sync.Mutex
	saveDirty       chan struct{}
	statePath       string
	config          HubConfig
	events          []WebhookEvent
	chatLog         []ChatEntry
	pendingCommands []PendingCommand
	phoneLastSeen   int64
	phoneReachable  bool
	lastDiscoveryAt time.Time
	lastPhoneStatus map[string]any
	adbBridgeActive bool
	adbBridgeDevice string

	sseMu      sync.Mutex
	sseClients map[chan []byte]struct{}

	waiterMu     sync.Mutex
	otpWaiters   map[*otpWaiter]struct{}
	readyWaiters map[*readyWaiter]struct{}

	httpClient *http.Client
}

var otpRegexes = []*regexp.Regexp{
	regexp.MustCompile(`(?i)(?:code|otp|码|驗證碼|验证码|动态码|校验码|確認コード)[^0-9]{0,16}([0-9]{4,8})`),
	regexp.MustCompile(`\b([0-9]{6})\b`),
	regexp.MustCompile(`\b([0-9]{4,8})\b`),
}

func extractOTP(body string) string {
	for _, re := range otpRegexes {
		m := re.FindStringSubmatch(body)
		if len(m) >= 2 {
			return m[1]
		}
	}
	return ""
}

func generateRandomToken(byteLen int) string {
	b := make([]byte, byteLen)
	if _, err := rand.Read(b); err != nil {
		return fmt.Sprintf("esim-hub-%d", time.Now().UnixNano())
	}
	return strings.TrimRight(base64.URLEncoding.EncodeToString(b), "=")
}

func defaultStatePath() string {
	// A service install keeps its state outside the binary directory.
	if override := strings.TrimSpace(os.Getenv("ESIM_HUB_STATE")); override != "" {
		return override
	}
	exe, err := os.Executable()
	if err == nil {
		dir := filepath.Dir(exe)
		return filepath.Join(dir, "esim-hub-state.json")
	}
	return "esim-hub-state.json"
}

func NewHubServer(statePath string) *HubServer {
	s := &HubServer{
		statePath:    statePath,
		saveDirty:    make(chan struct{}, 1),
		sseClients:   make(map[chan []byte]struct{}),
		otpWaiters:   make(map[*otpWaiter]struct{}),
		readyWaiters: make(map[*readyWaiter]struct{}),
		httpClient: &http.Client{
			// A card read right after a profile switch waits for the eUICC reset, so
			// the phone can take well over 15s to answer /api/v1/dashboard. A phone
			// that is simply off must still fail in seconds, which the dialer covers.
			Timeout: 60 * time.Second,
			Transport: &http.Transport{
				DialContext: (&net.Dialer{
					Timeout:   3 * time.Second,
					KeepAlive: 30 * time.Second,
				}).DialContext,
				ResponseHeaderTimeout: 55 * time.Second,
				MaxIdleConnsPerHost:   4,
			},
		},
		config: HubConfig{
			ListenAddr:      defaultListenAddr,
			WebhookToken:    generateRandomToken(24),
			RequireAuth:     false,
			PhoneGatewayURL: "",
			PhoneApiToken:   "",
			AutoCopyOTP:     true,
			DesktopNotify:   true,
			SoundAlert:      true,
			AutoOpenBrowser: true,
			FanoutTargets:   []FanoutTarget{},
		},
	}
	s.loadState()
	go s.runSaver()
	return s
}

func (s *HubServer) loadState() {
	data, err := os.ReadFile(s.statePath)
	if err != nil {
		if !os.IsNotExist(err) {
			log.Printf("state read failed (%v); starting from defaults", err)
		}
		s.saveState()
		return
	}
	var st PersistedState
	// Notepad and PowerShell's Set-Content write a UTF-8 BOM, which json.Unmarshal
	// rejects; a hand-edited state file must not silently reset every setting.
	data = bytes.TrimPrefix(data, []byte("\xef\xbb\xbf"))
	if err := json.Unmarshal(data, &st); err != nil {
		log.Printf("state file is not valid JSON (%v); keeping a copy at %s.corrupt", err, s.statePath)
		_ = os.WriteFile(s.statePath+".corrupt", data, 0600)
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if st.Config.ListenAddr != "" {
		s.config = st.Config
	}
	if s.config.WebhookToken == "" {
		s.config.WebhookToken = generateRandomToken(24)
	}
	s.events = st.Events
	s.chatLog = st.ChatLog
}

// markDirty schedules a save without blocking the caller. A single saver
// goroutine coalesces bursts (one SMS records an event and a chat line) so the
// file is written once instead of twice, and never by two goroutines at once.
func (s *HubServer) markDirty() {
	select {
	case s.saveDirty <- struct{}{}:
	default:
	}
}

func (s *HubServer) runSaver() {
	for range s.saveDirty {
		time.Sleep(120 * time.Millisecond)
		// Collapse anything queued while we slept.
		select {
		case <-s.saveDirty:
		default:
		}
		s.saveState()
	}
}

func (s *HubServer) saveState() {
	s.mu.RLock()
	st := PersistedState{
		Config:  s.config,
		Events:  s.events,
		ChatLog: s.chatLog,
	}
	s.mu.RUnlock()
	data, err := json.MarshalIndent(st, "", "  ")
	if err != nil {
		log.Printf("state marshal failed: %v", err)
		return
	}
	// Two goroutines can reach here at once (an SMS records an event and a chat
	// line), and os.WriteFile truncates before writing, so concurrent writers
	// interleave into a file that no longer parses. A failed parse then silently
	// resets every setting, including the webhook token the phone depends on.
	s.saveMu.Lock()
	defer s.saveMu.Unlock()
	tmp := s.statePath + ".tmp"
	if err := os.WriteFile(tmp, data, 0600); err != nil {
		log.Printf("state write failed: %v", err)
		return
	}
	if err := os.Rename(tmp, s.statePath); err != nil {
		log.Printf("state rename failed: %v", err)
		_ = os.Remove(tmp)
	}
}

func (s *HubServer) broadcastSSE(eventType string, payload any) {
	body, err := json.Marshal(map[string]any{
		"type":      eventType,
		"timestamp": time.Now().UnixMilli(),
		"data":      payload,
	})
	if err != nil {
		return
	}
	msg := []byte(fmt.Sprintf("data: %s\n\n", string(body)))
	s.sseMu.Lock()
	defer s.sseMu.Unlock()
	for ch := range s.sseClients {
		select {
		case ch <- msg:
		default:
		}
	}
}

func (s *HubServer) appendChat(role, text string, keyboard [][]BotButton) ChatEntry {
	entry := ChatEntry{
		ID:        fmt.Sprintf("chat_%d", time.Now().UnixNano()),
		Role:      role,
		Text:      text,
		Keyboard:  keyboard,
		Timestamp: time.Now().UnixMilli(),
	}
	s.mu.Lock()
	s.chatLog = append(s.chatLog, entry)
	if len(s.chatLog) > maxChatItems {
		s.chatLog = s.chatLog[len(s.chatLog)-maxChatItems:]
	}
	s.mu.Unlock()
	s.markDirty()
	s.broadcastSSE("chat", entry)
	return entry
}

func parseKeyboard(raw json.RawMessage) [][]BotButton {
	if len(raw) == 0 {
		return nil
	}
	var markup BotReplyMarkup
	if err := json.Unmarshal(raw, &markup); err == nil && len(markup.InlineKeyboard) > 0 {
		return markup.InlineKeyboard
	}
	var direct [][]BotButton
	if err := json.Unmarshal(raw, &direct); err == nil && len(direct) > 0 {
		return direct
	}
	return nil
}

func listLocalIPv4s() []string {
	var ips []string
	ifaces, err := net.Interfaces()
	if err != nil {
		return []string{"127.0.0.1"}
	}
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, a := range addrs {
			var ip net.IP
			switch v := a.(type) {
			case *net.IPNet:
				ip = v.IP
			case *net.IPAddr:
				ip = v.IP
			}
			if ip == nil {
				continue
			}
			ip4 := ip.To4()
			if ip4 == nil {
				continue
			}
			s := ip4.String()
			if strings.HasPrefix(s, "169.254.") {
				continue
			}
			ips = append(ips, s)
		}
	}
	ips = append(ips, "127.0.0.1")
	return ips
}

func extractRemoteHost(remoteAddr string) string {
	host, _, err := net.SplitHostPort(remoteAddr)
	if err != nil {
		return remoteAddr
	}
	return strings.Trim(host, "[]")
}

func (s *HubServer) updatePhoneDiscovery(ev WebhookEvent, remoteIP string) {
	port := ev.GatewayPort
	if port <= 0 {
		port = 8787
	}
	// Only an address the hub can dial back counts. A phone on cellular reports
	// its carrier NAT address as the request source, which is not routable from
	// here, so a public address must never be adopted as the gateway.
	var candidateHost string
	if isDialableGatewayHost(ev.GatewayAddress) {
		candidateHost = ev.GatewayAddress
	} else {
		for _, a := range ev.GatewayAddresses {
			if isDialableGatewayHost(a) {
				candidateHost = a
				break
			}
		}
	}
	if candidateHost == "" && isDialableGatewayHost(remoteIP) {
		candidateHost = remoteIP
	}

	s.mu.Lock()
	s.phoneLastSeen = time.Now().UnixMilli()
	s.phoneReachable = true
	adopted := ""
	if s.config.PhoneGatewayURL == "" && candidateHost != "" {
		s.config.PhoneGatewayURL = fmt.Sprintf("http://%s:%d", candidateHost, port)
		adopted = s.config.PhoneGatewayURL
	}
	s.mu.Unlock()
	if adopted != "" {
		// The phone may report a LAN address the hub cannot route to (a server
		// on another network, for example). Confirm before trusting it, or every
		// later call wastes its dial timeout on a dead address.
		go s.verifyAdoptedGateway(adopted)
	}
}

func (s *HubServer) verifyAdoptedGateway(url string) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	token := s.getPhoneBearerToken()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url+"/api/v1/status", nil)
	if err != nil {
		return
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := s.httpClient.Do(req)
	if err == nil {
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
		resp.Body.Close()
		if resp.StatusCode == http.StatusOK {
			return
		}
	}
	s.mu.Lock()
	if s.config.PhoneGatewayURL == url {
		s.config.PhoneGatewayURL = ""
	}
	s.mu.Unlock()
	s.saveState()
}

// isDialableGatewayHost reports whether the hub can open a TCP connection to
// this address: loopback, RFC1918, or the Tailscale CGNAT range.
func isDialableGatewayHost(host string) bool {
	host = strings.Trim(strings.TrimSpace(host), "[]")
	if host == "" || host == "0.0.0.0" {
		return false
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return false
	}
	if ip.IsLoopback() {
		return true
	}
	ip4 := ip.To4()
	if ip4 == nil {
		// Tailscale hands out addresses in fd7a:115c:a1e0::/48.
		return strings.HasPrefix(strings.ToLower(host), "fd7a:115c:a1e0:")
	}
	if ip4[0] == 10 || (ip4[0] == 192 && ip4[1] == 168) ||
		(ip4[0] == 172 && ip4[1] >= 16 && ip4[1] <= 31) {
		return true
	}
	return ip4[0] == 100 && ip4[1] >= 64 && ip4[1] <= 127
}

func constantTimeEquals(a, b string) bool {
	if len(a) != len(b) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1
}

func (s *HubServer) handleWebhook(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "method_not_allowed"})
		return
	}

	s.mu.RLock()
	requireAuth := s.config.RequireAuth
	expectedToken := s.config.WebhookToken
	autoCopy := s.config.AutoCopyOTP
	desktopNotify := s.config.DesktopNotify
	soundAlert := s.config.SoundAlert
	s.mu.RUnlock()

	authHeader := strings.TrimSpace(r.Header.Get("Authorization"))
	suppliedToken := ""
	if lower := strings.ToLower(authHeader); strings.HasPrefix(lower, "bearer ") {
		suppliedToken = strings.TrimSpace(authHeader[len("bearer "):])
	}
	if requireAuth && expectedToken != "" {
		if !constantTimeEquals(suppliedToken, expectedToken) {
			writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "unauthorized"})
			return
		}
	}

	bodyBytes, err := io.ReadAll(io.LimitReader(r.Body, 256*1024))
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "read_failed"})
		return
	}
	var ev WebhookEvent
	if err := json.Unmarshal(bodyBytes, &ev); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid_json"})
		return
	}
	if ev.ReceivedAtEpochMillis == 0 {
		ev.ReceivedAtEpochMillis = time.Now().UnixMilli()
	}
	if ev.ID == "" {
		if ev.MessageID != "" {
			ev.ID = ev.MessageID
		} else {
			ev.ID = fmt.Sprintf("ev_%d", time.Now().UnixNano())
		}
	}
	ev.RemoteIP = extractRemoteHost(r.RemoteAddr)
	// A simulated message is produced locally: it must not move the discovered
	// gateway address, and it must not consume commands queued for the phone.
	simulated := r.Header.Get("X-Hub-Simulated") == "1"
	if !simulated {
		s.updatePhoneDiscovery(ev, ev.RemoteIP)
	}

	if ev.Event == "" {
		if ev.Body != "" || ev.Sender != "" {
			ev.Event = "sms.received"
		} else if ev.Text != "" {
			ev.Event = "gateway.notification"
		} else {
			ev.Event = "webhook.raw"
		}
	}

	switch ev.Event {
	case "gateway.heartbeat":
		s.broadcastSSE("heartbeat", map[string]any{
			"phoneLastSeen":   time.Now().UnixMilli(),
			"phoneGatewayUrl": s.getPhoneGatewayURL(),
			"remoteIp":        ev.RemoteIP,
		})
	case "sms.received":
		if ev.OTP == "" && ev.Body != "" {
			ev.OTP = extractOTP(ev.Body)
		}
		s.recordEvent(ev)
		chatText := fmt.Sprintf("📩 【收到新短信】\n发件人：%s\n卡槽/运营商：SIM %s (%s)\n内容：%s",
			nonEmpty(ev.Sender, "未知号码"),
			formatSlot(ev.SlotIndex),
			nonEmpty(ev.CarrierName, "未知运营商"),
			ev.Body,
		)
		if ev.OTP != "" {
			chatText += fmt.Sprintf("\n🔑 提取验证码：【 %s 】", ev.OTP)
		}
		s.appendChat("event", chatText, nil)
		if ev.OTP != "" && autoCopy {
			go copyToWindowsClipboard(ev.OTP)
		}
		if desktopNotify {
			title := fmt.Sprintf("📩 短信: %s", nonEmpty(ev.Sender, "未知"))
			if ev.OTP != "" {
				title = fmt.Sprintf("🔑 验证码 %s (%s)", ev.OTP, nonEmpty(ev.Sender, "短信"))
			}
			go notifyWindowsDesktop(title, ev.Body, soundAlert)
		}
		s.notifyOTPWaiters(ev)
		go s.fanoutEvent(ev)

	case "call.ringing":
		s.recordEvent(ev)
		chatText := fmt.Sprintf("📞 【呼入电话振铃】\n来电号码：%s\n卡槽/运营商：SIM %s (%s)",
			nonEmpty(ev.Caller, "未知号码"),
			formatSlot(ev.SlotIndex),
			nonEmpty(ev.CarrierName, "未知运营商"),
		)
		s.appendChat("event", chatText, nil)
		if desktopNotify {
			go notifyWindowsDesktop("📞 备用机来电提醒", fmt.Sprintf("号码: %s (%s)", ev.Caller, ev.CarrierName), soundAlert)
		}
		go s.fanoutEvent(ev)

	case "gateway.notification", "gateway.command_result":
		s.recordEvent(ev)
		kb := parseKeyboard(ev.ReplyMarkup)
		s.appendChat("bot", nonEmpty(ev.Text, ev.Body), kb)
		if strings.Contains(ev.Text, "切卡成功") || strings.Contains(ev.Text, "基带已注册") {
			s.notifyReadyWaiters(ev)
		}
		if desktopNotify && ev.Event == "gateway.notification" {
			go notifyWindowsDesktop("🤖 eSIM-Matrix 网关通知", truncateText(ev.Text, 120), soundAlert)
		}
		go s.fanoutEvent(ev)

	default:
		s.recordEvent(ev)
	}

	// Drain and return any queued reverse commands so the phone executes them immediately!
	s.mu.Lock()
	var pending []PendingCommand
	if !simulated {
		pending = s.pendingCommands
		s.pendingCommands = nil
	}
	s.mu.Unlock()

	writeJSON(w, http.StatusOK, map[string]any{
		"ok":              true,
		"receivedAt":      time.Now().UnixMilli(),
		"pendingCommands": pending,
	})
}

func (s *HubServer) recordEvent(ev WebhookEvent) {
	s.mu.Lock()
	s.events = append([]WebhookEvent{ev}, s.events...)
	if len(s.events) > maxHistoryItems {
		s.events = s.events[:maxHistoryItems]
	}
	s.mu.Unlock()
	s.markDirty()
	s.broadcastSSE("webhook_event", ev)
}

func (s *HubServer) notifyOTPWaiters(ev WebhookEvent) {
	if ev.OTP == "" {
		return
	}
	s.waiterMu.Lock()
	defer s.waiterMu.Unlock()
	for w := range s.otpWaiters {
		if w.senderContains != "" {
			target := strings.ToLower(w.senderContains)
			if !strings.Contains(strings.ToLower(ev.Sender), target) &&
				!strings.Contains(strings.ToLower(ev.Body), target) {
				continue
			}
		}
		select {
		case w.ch <- ev:
		default:
		}
	}
}

func (s *HubServer) notifyReadyWaiters(ev WebhookEvent) {
	s.waiterMu.Lock()
	defer s.waiterMu.Unlock()
	for w := range s.readyWaiters {
		select {
		case w.ch <- ev:
		default:
		}
	}
}

func (s *HubServer) getPhoneGatewayURL() string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return strings.TrimRight(strings.TrimSpace(s.config.PhoneGatewayURL), "/")
}

func (s *HubServer) getPhoneBearerToken() string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if strings.TrimSpace(s.config.PhoneApiToken) != "" {
		return strings.TrimSpace(s.config.PhoneApiToken)
	}
	return strings.TrimSpace(s.config.WebhookToken)
}

func (s *HubServer) callPhoneAPI(ctx context.Context, method, apiPath string, payload any) (int, []byte, error) {
	code, respBytes, err := s.doCallPhoneAPIOnce(ctx, s.getPhoneGatewayURL(), method, apiPath, payload)
	if err != nil && strings.Contains(s.getPhoneGatewayURL(), "127.0.0.1:18787") {
		// Auto-heal ADB forward tunnel if USB was re-plugged.
		adb := s.findADBExecutable()
		_ = exec.CommandContext(ctx, adb, "forward", "tcp:18787", "tcp:8787").Run()
		code, respBytes, err = s.doCallPhoneAPIOnce(ctx, s.getPhoneGatewayURL(), method, apiPath, payload)
	}
	if err != nil {
		// DHCP moves the phone between sessions, so a stale address must not
		// disable the whole console until someone retypes an IP by hand.
		if discovered := s.discoverPhoneGateway(ctx); discovered != "" {
			code, respBytes, err = s.doCallPhoneAPIOnce(ctx, discovered, method, apiPath, payload)
			if err == nil {
				s.mu.Lock()
				s.config.PhoneGatewayURL = discovered
				s.mu.Unlock()
				s.saveState()
			}
		}
	}
	if err != nil {
		// A caller that hung up (page refresh, CLI timeout) is not evidence that
		// the phone moved; clearing the address here would break the next call.
		if ctx.Err() != nil {
			return code, respBytes, err
		}
		// Nothing answered. Drop the saved address so the next heartbeat can
		// adopt a fresh one; a stale URL otherwise blocks re-discovery forever.
		s.mu.Lock()
		if s.config.PhoneGatewayURL != "" {
			s.config.PhoneGatewayURL = ""
			s.adbBridgeActive = false
			s.adbBridgeDevice = ""
			s.mu.Unlock()
			s.saveState()
		} else {
			s.mu.Unlock()
		}
	}
	return code, respBytes, err
}

// discoverPhoneGateway probes port 8787 across the local /24 and adopts the one
// host that answers the gateway's own status endpoint.
//
// The scan is capped hard: it runs on the request path, so a phone that is
// simply off must not stall every console call for the length of a full sweep.
func (s *HubServer) discoverPhoneGateway(ctx context.Context) string {
	s.mu.RLock()
	last := s.lastDiscoveryAt
	s.mu.RUnlock()
	if time.Since(last) < 30*time.Second {
		return ""
	}
	s.mu.Lock()
	s.lastDiscoveryAt = time.Now()
	s.mu.Unlock()

	hosts := localSubnetHosts()
	if len(hosts) == 0 {
		return ""
	}
	scanCtx, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()

	token := s.getPhoneBearerToken()
	found := make(chan string, 1)
	probeClient := &http.Client{Timeout: 1200 * time.Millisecond}
	sem := make(chan struct{}, 96)
	var wg sync.WaitGroup
	for _, host := range hosts {
		wg.Add(1)
		go func(host string) {
			defer wg.Done()
			select {
			case sem <- struct{}{}:
			case <-scanCtx.Done():
				return
			}
			defer func() { <-sem }()
			base := fmt.Sprintf("http://%s:8787", host)
			// Identify the gateway without credentials first: broadcasting the
			// bearer token to every host on the /24 would hand it to any listener.
			helloReq, helloErr := http.NewRequestWithContext(scanCtx, http.MethodGet, base+"/", nil)
			if helloErr != nil {
				return
			}
			helloResp, helloDoErr := probeClient.Do(helloReq)
			if helloDoErr != nil {
				return
			}
			_, _ = io.Copy(io.Discard, io.LimitReader(helloResp.Body, 4096))
			helloResp.Body.Close()
			if !strings.Contains(helloResp.Header.Get("Server"), "eSIM-Matrix Gateway") {
				return
			}

			req, reqErr := http.NewRequestWithContext(scanCtx, http.MethodGet, base+"/api/v1/status", nil)
			if reqErr != nil {
				return
			}
			if token != "" {
				req.Header.Set("Authorization", "Bearer "+token)
			}
			resp, doErr := probeClient.Do(req)
			if doErr != nil {
				return
			}
			defer resp.Body.Close()
			_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
			if resp.StatusCode == http.StatusOK {
				select {
				case found <- base:
				default:
				}
			}
		}(host)
	}
	wg.Wait()
	select {
	case url := <-found:
		return url
	default:
		return ""
	}
}

// localSubnetHosts returns every usable IPv4 address on the machine's own /24.
func localSubnetHosts() []string {
	var hosts []string
	seen := map[string]struct{}{}
	for _, ipStr := range listLocalIPv4s() {
		ip := net.ParseIP(ipStr).To4()
		if ip == nil || ip.IsLoopback() {
			continue
		}
		prefix := fmt.Sprintf("%d.%d.%d.", ip[0], ip[1], ip[2])
		if _, ok := seen[prefix]; ok {
			continue
		}
		seen[prefix] = struct{}{}
		for i := 1; i < 255; i++ {
			candidate := fmt.Sprintf("%s%d", prefix, i)
			if candidate == ipStr {
				continue
			}
			hosts = append(hosts, candidate)
		}
	}
	return hosts
}

func (s *HubServer) doCallPhoneAPIOnce(ctx context.Context, baseURL, method, apiPath string, payload any) (int, []byte, error) {
	if baseURL == "" {
		return 0, nil, errors.New("phone_gateway_url_not_configured")
	}
	fullURL := baseURL + apiPath
	var bodyReader io.Reader
	if payload != nil {
		switch v := payload.(type) {
		case []byte:
			bodyReader = bytes.NewReader(v)
		case string:
			bodyReader = strings.NewReader(v)
		default:
			b, err := json.Marshal(payload)
			if err != nil {
				return 0, nil, err
			}
			bodyReader = bytes.NewReader(b)
		}
	}
	req, err := http.NewRequestWithContext(ctx, method, fullURL, bodyReader)
	if err != nil {
		return 0, nil, err
	}
	token := s.getPhoneBearerToken()
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	if bodyReader != nil {
		req.Header.Set("Content-Type", "application/json; charset=utf-8")
	}
	req.Header.Set("Accept", "application/json")

	resp, err := s.httpClient.Do(req)
	if err != nil {
		s.mu.Lock()
		s.phoneReachable = false
		s.mu.Unlock()
		return 0, nil, err
	}
	defer resp.Body.Close()
	respBytes, err := io.ReadAll(io.LimitReader(resp.Body, 2*1024*1024))
	if err != nil {
		return resp.StatusCode, nil, err
	}
	s.mu.Lock()
	s.phoneReachable = true
	s.phoneLastSeen = time.Now().UnixMilli()
	s.mu.Unlock()
	return resp.StatusCode, respBytes, nil
}

// handlePhoneProxy transparently proxies /api/phone/<subpath> -> <PhoneGatewayURL>/api/v1/<subpath>.
func (s *HubServer) handlePhoneProxy(w http.ResponseWriter, r *http.Request) {
	subpath := strings.TrimPrefix(r.URL.Path, "/api/phone")
	if subpath == "" || subpath == "/" {
		subpath = "/status"
	}
	apiPath := "/api/v1" + subpath
	if r.URL.RawQuery != "" {
		apiPath += "?" + r.URL.RawQuery
	}
	var reqBody []byte
	if r.Body != nil && (r.Method == http.MethodPost || r.Method == http.MethodPut || r.Method == http.MethodPatch) {
		// Truncating a body silently turns a valid request into invalid JSON.
		limited := http.MaxBytesReader(w, r.Body, 128<<10)
		var readErr error
		reqBody, readErr = io.ReadAll(limited)
		if readErr != nil {
			writeJSON(w, http.StatusRequestEntityTooLarge, map[string]any{"error": "request_too_large"})
			return
		}
	}
	code, respBytes, err := s.callPhoneAPI(r.Context(), r.Method, apiPath, reqBody)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]any{
			"error":   "phone_unreachable",
			"message": fmt.Sprintf("无法直连手机网关 (%s): %v。可使用「ADB 一键免配桥接」或等待手机 Webhook 心跳反向同步。", s.getPhoneGatewayURL(), err),
		})
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_, _ = w.Write(respBytes)
}

// handleLocalBot executes a TG Bot command or callback button and logs it to the interactive chat console.
func (s *HubServer) handleLocalBot(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "method_not_allowed"})
		return
	}
	var req struct {
		Text         string `json:"text"`
		CallbackData string `json:"callbackData"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 32*1024)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid_json"})
		return
	}
	displayCmd := strings.TrimSpace(req.Text)
	if displayCmd == "" && req.CallbackData != "" {
		displayCmd = "[按钮] " + req.CallbackData
	}
	if displayCmd != "" {
		s.appendChat("user", displayCmd, nil)
	}

	ctx, cancel := context.WithTimeout(r.Context(), 25*time.Second)
	defer cancel()
	code, respBytes, err := s.callPhoneAPI(ctx, http.MethodPost, "/api/v1/bot", map[string]any{
		"text":         req.Text,
		"callbackData": req.CallbackData,
	})
	if err == nil && code >= 200 && code < 300 {
		var parsed struct {
			Text        string          `json:"text"`
			ReplyMarkup json.RawMessage `json:"reply_markup"`
		}
		if json.Unmarshal(respBytes, &parsed) == nil && parsed.Text != "" {
			kb := parseKeyboard(parsed.ReplyMarkup)
			entry := s.appendChat("bot", parsed.Text, kb)
			writeJSON(w, http.StatusOK, map[string]any{
				"ok":       true,
				"mode":     "direct",
				"reply":    entry,
				"rawReply": json.RawMessage(respBytes),
			})
			return
		}
	}

	// Fallback: if /api/v1/bot returned 404 (older APK) or we can translate to standard REST calls, try local REST translation!
	if err == nil && code == http.StatusNotFound {
		fallbackEntry, fbErr := s.executeBotCommandViaREST(ctx, req.Text, req.CallbackData)
		if fbErr == nil {
			writeJSON(w, http.StatusOK, map[string]any{
				"ok":    true,
				"mode":  "rest_fallback",
				"reply": fallbackEntry,
			})
			return
		}
	}

	// If phone is unreachable via direct TCP, queue in pendingCommands for next webhook/heartbeat!
	cmd := PendingCommand{
		ID:           fmt.Sprintf("cmd_%d", time.Now().UnixNano()),
		Text:         req.Text,
		CallbackData: req.CallbackData,
		CreatedAt:    time.Now().UnixMilli(),
	}
	s.mu.Lock()
	s.pendingCommands = append(s.pendingCommands, cmd)
	s.mu.Unlock()

	errMsg := "手机当前未开启直连网关，指令已加入反向心跳队列（手机下次推送 Webhook 或心跳时将自动执行）"
	if err != nil {
		errMsg = fmt.Sprintf("📡 直连手机暂不可达 (%v)\n⏳ 已将指令 `%s` 加入反向捎带队列，手机下次心跳/推送时立即执行；或点击右上角「🔌 ADB 一键桥接」打通数据线/局域网直连。", err, displayCmd)
	} else if code == http.StatusUnauthorized {
		errMsg = "🔒 手机网关鉴权失败 (HTTP 401)：请在设置中填入手机远程网关的 API Token，或点击「🔌 ADB 一键桥接」自动同步 Token。"
	}
	entry := s.appendChat("bot", errMsg, nil)
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":     false,
		"queued": true,
		"reply":  entry,
	})
}

// executeBotCommandViaREST translates TG Bot commands into standard /api/v1/* calls so even older APKs work seamlessly.
func (s *HubServer) executeBotCommandViaREST(ctx context.Context, text, callbackData string) (ChatEntry, error) {
	cmd := strings.TrimSpace(text)
	if callbackData != "" {
		switch {
		case callbackData == "cmd:status":
			cmd = "/status"
		case callbackData == "cmd:list":
			cmd = "/list"
		case callbackData == "cmd:back":
			cmd = "/back"
		case callbackData == "cmd:kick" || callbackData == "kick:now":
			cmd = "/kick"
		case callbackData == "cmd:retry_sms":
			cmd = "/retry_sms"
		case callbackData == "cmd:keepalive":
			cmd = "/keepalive"
		case callbackData == "cmd:readers":
			cmd = "/readers"
		case strings.HasPrefix(callbackData, "use:"):
			cmd = "/use " + strings.TrimPrefix(callbackData, "use:")
		case strings.HasPrefix(callbackData, "use_temp:"):
			cmd = "/use_temp " + strings.TrimPrefix(callbackData, "use_temp:")
		}
	}
	parts := strings.Fields(cmd)
	if len(parts) == 0 {
		parts = []string{"/status"}
	}
	verb := strings.TrimPrefix(strings.ToLower(parts[0]), "/")
	arg := strings.TrimSpace(strings.TrimPrefix(cmd, parts[0]))

	defaultKB := [][]BotButton{
		{
			{Text: "📡 刷新状态", CallbackData: "cmd:status"},
			{Text: "📋 卡内列表", CallbackData: "cmd:list"},
			{Text: "⚡ 踢网重搜", CallbackData: "cmd:kick"},
			{Text: "🏠 切回主卡", CallbackData: "cmd:back"},
		},
	}

	switch verb {
	case "status", "start", "help", "menu":
		_, b, err := s.callPhoneAPI(ctx, http.MethodGet, "/api/v1/status", nil)
		if err != nil {
			return ChatEntry{}, err
		}
		var m map[string]any
		_ = json.Unmarshal(b, &m)
		pretty, _ := json.MarshalIndent(m, "", "  ")
		return s.appendChat("bot", "📡 手机状态快照：\n"+string(pretty), defaultKB), nil
	case "list", "profiles":
		_, b, err := s.callPhoneAPI(ctx, http.MethodGet, "/api/v1/profiles", nil)
		if err != nil {
			return ChatEntry{}, err
		}
		return s.appendChat("bot", "📋 卡内 eSIM 列表：\n"+string(b), defaultKB), nil
	case "use", "use_temp":
		dur := 0
		if verb == "use_temp" {
			dur = 5
		}
		_, b, err := s.callPhoneAPI(ctx, http.MethodPost, "/api/v1/switch", map[string]any{
			"profile":         arg,
			"durationMinutes": dur,
		})
		if err != nil {
			return ChatEntry{}, err
		}
		return s.appendChat("bot", "⚡ 切卡响应：\n"+string(b), defaultKB), nil
	case "back":
		_, b, err := s.callPhoneAPI(ctx, http.MethodPost, "/api/v1/back", map[string]any{})
		if err != nil {
			return ChatEntry{}, err
		}
		return s.appendChat("bot", "🏠 已切回默认主卡：\n"+string(b), defaultKB), nil
	case "default", "set_default":
		_, b, err := s.callPhoneAPI(ctx, http.MethodPost, "/api/v1/default", map[string]any{})
		if err != nil {
			return ChatEntry{}, err
		}
		return s.appendChat("bot", "📌 已设当前卡为默认主卡：\n"+string(b), defaultKB), nil
	case "kick":
		_, b, err := s.callPhoneAPI(ctx, http.MethodPost, "/api/v1/network/kick", map[string]any{})
		if err != nil {
			return ChatEntry{}, err
		}
		return s.appendChat("bot", "⚡ 已触发基带重搜网：\n"+string(b), defaultKB), nil
	case "location_stop":
		_, b, err := s.callPhoneAPI(ctx, http.MethodDelete, "/api/v1/location", nil)
		if err != nil {
			return ChatEntry{}, err
		}
		return s.appendChat("bot", "⚪ 已停止虚拟定位：\n"+string(b), defaultKB), nil
	default:
		return ChatEntry{}, errors.New("unsupported_fallback_command")
	}
}

func (s *HubServer) handleLatestOTP(w http.ResponseWriter, r *http.Request) {
	senderFilter := strings.TrimSpace(r.URL.Query().Get("sender"))
	waitSec := 0
	if v := r.URL.Query().Get("wait"); v != "" {
		_, _ = fmt.Sscanf(v, "%d", &waitSec)
	}
	afterMillis := int64(0)
	if v := r.URL.Query().Get("after"); v != "" {
		_, _ = fmt.Sscanf(v, "%d", &afterMillis)
	}

	// Register first, then scan: a message that lands between the two would
	// otherwise be recorded but never delivered to this waiter.
	waiter := &otpWaiter{
		senderContains: senderFilter,
		ch:             make(chan WebhookEvent, 1),
	}
	if waitSec > 0 {
		s.waiterMu.Lock()
		s.otpWaiters[waiter] = struct{}{}
		s.waiterMu.Unlock()
		defer func() {
			s.waiterMu.Lock()
			delete(s.otpWaiters, waiter)
			s.waiterMu.Unlock()
		}()
	}

	// Check existing events first unless onlyNew=1 is passed.
	if r.URL.Query().Get("onlyNew") != "1" {
		s.mu.RLock()
		for _, ev := range s.events {
			if ev.Event == "sms.received" && ev.OTP != "" && ev.ReceivedAtEpochMillis >= afterMillis {
				if senderFilter == "" ||
					strings.Contains(strings.ToLower(ev.Sender), strings.ToLower(senderFilter)) ||
					strings.Contains(strings.ToLower(ev.Body), strings.ToLower(senderFilter)) {
					s.mu.RUnlock()
					writeJSON(w, http.StatusOK, map[string]any{
						"ok":    true,
						"otp":   ev.OTP,
						"event": ev,
					})
					return
				}
			}
		}
		s.mu.RUnlock()
	}

	if waitSec <= 0 {
		writeJSON(w, http.StatusNotFound, map[string]any{"ok": false, "error": "otp_not_found"})
		return
	}
	if waitSec > 300 {
		waitSec = 300
	}

	select {
	case ev := <-waiter.ch:
		writeJSON(w, http.StatusOK, map[string]any{
			"ok":    true,
			"otp":   ev.OTP,
			"event": ev,
		})
	case <-time.After(time.Duration(waitSec) * time.Second):
		writeJSON(w, http.StatusRequestTimeout, map[string]any{
			"ok":    false,
			"error": "wait_timeout",
		})
	case <-r.Context().Done():
	}
}

// handleSwitchAndWaitOTP automates the full closed loop:
// 1. Switch to target eSIM profile
// 2. Wait for baseband registration (or incoming SMS)
// 3. Wait for OTP SMS webhook arrival
// 4. Automatically revert back to default profile if autoBack=true
func (s *HubServer) handleSwitchAndWaitOTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "method_not_allowed"})
		return
	}
	var req struct {
		Profile         string `json:"profile"`
		DurationMinutes int    `json:"durationMinutes"`
		SenderContains  string `json:"senderContains"`
		TimeoutSeconds  int    `json:"timeoutSeconds"`
		AutoBack        *bool  `json:"autoBack"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 32*1024)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid_json"})
		return
	}
	if strings.TrimSpace(req.Profile) == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "profile_required"})
		return
	}
	if req.DurationMinutes <= 0 {
		req.DurationMinutes = 5
	}
	if req.TimeoutSeconds <= 0 {
		req.TimeoutSeconds = 120
	}
	if req.TimeoutSeconds > 600 {
		req.TimeoutSeconds = 600
	}
	autoBack := true
	if req.AutoBack != nil {
		autoBack = *req.AutoBack
	}

	waiter := &otpWaiter{
		senderContains: req.SenderContains,
		ch:             make(chan WebhookEvent, 1),
	}
	s.waiterMu.Lock()
	s.otpWaiters[waiter] = struct{}{}
	s.waiterMu.Unlock()
	defer func() {
		s.waiterMu.Lock()
		delete(s.otpWaiters, waiter)
		s.waiterMu.Unlock()
	}()

	startTime := time.Now()
	s.appendChat("user", fmt.Sprintf("🤖 [自动接码闭环] 切换至【%s】等待验证码 (超时 %ds)...", req.Profile, req.TimeoutSeconds), nil)

	code, switchBytes, err := s.callPhoneAPI(r.Context(), http.MethodPost, "/api/v1/switch", map[string]any{
		"profile":          req.Profile,
		"temporaryMinutes": req.DurationMinutes,
		"durationMinutes":  req.DurationMinutes,
	})
	if err != nil || code >= 400 {
		writeJSON(w, http.StatusBadGateway, map[string]any{
			"ok":           false,
			"error":        "switch_failed",
			"statusCode":   code,
			"phoneMessage": string(switchBytes),
			"detail":       fmt.Sprintf("%v", err),
		})
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), time.Duration(req.TimeoutSeconds)*time.Second)
	defer cancel()

	select {
	case ev := <-waiter.ch:
		reverted := false
		if autoBack {
			revertCtx, rCancel := context.WithTimeout(context.Background(), 20*time.Second)
			rCode, _, rErr := s.callPhoneAPI(revertCtx, http.MethodPost, "/api/v1/back", map[string]any{})
			rCancel()
			reverted = (rErr == nil && rCode >= 200 && rCode < 300)
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"ok":            true,
			"otp":           ev.OTP,
			"sender":        ev.Sender,
			"body":          ev.Body,
			"carrierName":   ev.CarrierName,
			"slotIndex":     ev.SlotIndex,
			"elapsedMillis": time.Since(startTime).Milliseconds(),
			"reverted":      reverted,
			"event":         ev,
		})
	case <-ctx.Done():
		writeJSON(w, http.StatusRequestTimeout, map[string]any{
			"ok":            false,
			"error":         "otp_wait_timeout",
			"elapsedMillis": time.Since(startTime).Milliseconds(),
		})
	}
}

func (s *HubServer) handleSSE(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "Streaming unsupported", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("Access-Control-Allow-Origin", "*")

	ch := make(chan []byte, 32)
	s.sseMu.Lock()
	s.sseClients[ch] = struct{}{}
	s.sseMu.Unlock()
	defer func() {
		s.sseMu.Lock()
		delete(s.sseClients, ch)
		s.sseMu.Unlock()
	}()

	_, _ = w.Write([]byte("data: {\"type\":\"connected\"}\n\n"))
	flusher.Flush()

	ticker := time.NewTicker(20 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case msg := <-ch:
			_, _ = w.Write(msg)
			flusher.Flush()
		case <-ticker.C:
			_, _ = w.Write([]byte(": keepalive\n\n"))
			flusher.Flush()
		case <-r.Context().Done():
			return
		}
	}
}

func (s *HubServer) handleLocalState(w http.ResponseWriter, r *http.Request) {
	localIPs := listLocalIPv4s()
	s.mu.RLock()
	cfg := s.config
	events := s.events
	chatLog := s.chatLog
	lastSeen := s.phoneLastSeen
	reachable := s.phoneReachable
	adbActive := s.adbBridgeActive
	adbDev := s.adbBridgeDevice
	pendingCount := len(s.pendingCommands)
	s.mu.RUnlock()

	port := defaultPort
	if _, pStr, err := net.SplitHostPort(cfg.ListenAddr); err == nil {
		_, _ = fmt.Sscanf(pStr, "%d", &port)
	}
	var webhookURLs []string
	// A reverse proxy in front of the hub is the only address a phone on mobile
	// data can reach, so it belongs at the top of the list the UI offers.
	if public := strings.TrimSpace(os.Getenv("ESIM_HUB_PUBLIC_URL")); public != "" {
		webhookURLs = append(webhookURLs, strings.TrimRight(public, "/")+"/webhook")
	}
	for _, ip := range localIPs {
		webhookURLs = append(webhookURLs, fmt.Sprintf("http://%s:%d/webhook", ip, port))
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"config":          cfg,
		"localIps":        localIPs,
		"webhookUrls":     webhookURLs,
		"events":          events,
		"chatLog":         chatLog,
		"phoneLastSeen":   lastSeen,
		"phoneReachable":  reachable,
		"adbBridgeActive": adbActive,
		"adbBridgeDevice": adbDev,
		"pendingCommands": pendingCount,
		"presetLocations": defaultPresetLocations,
	})
}

func (s *HubServer) handleSaveConfig(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "method_not_allowed"})
		return
	}
	var req struct {
		Config      HubConfig `json:"config"`
		PushToPhone bool      `json:"pushToPhone"`
		WebhookURL  string    `json:"webhookUrl"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 128*1024)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid_json"})
		return
	}
	s.mu.Lock()
	if req.Config.ListenAddr != "" {
		s.config.ListenAddr = req.Config.ListenAddr
	}
	if req.Config.WebhookToken != "" {
		s.config.WebhookToken = strings.TrimSpace(req.Config.WebhookToken)
	}
	s.config.RequireAuth = req.Config.RequireAuth
	s.config.PhoneGatewayURL = strings.TrimRight(strings.TrimSpace(req.Config.PhoneGatewayURL), "/")
	if trimmed := strings.TrimSpace(req.Config.PhoneApiToken); trimmed != "" {
		// An empty field means "unchanged": the UI round-trips the state object and
		// a blank token must not silently fall back to the webhook token.
		s.config.PhoneApiToken = trimmed
	}
	s.config.AutoCopyOTP = req.Config.AutoCopyOTP
	s.config.DesktopNotify = req.Config.DesktopNotify
	s.config.SoundAlert = req.Config.SoundAlert
	s.config.AutoOpenBrowser = req.Config.AutoOpenBrowser
	if req.Config.FanoutTargets != nil {
		s.config.FanoutTargets = req.Config.FanoutTargets
	}
	cfgCopy := s.config
	s.mu.Unlock()
	s.saveState()

	phoneSynced := false
	var syncDetail string
	if req.PushToPhone && cfgCopy.PhoneGatewayURL != "" && req.WebhookURL != "" {
		ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
		code, respBytes, err := s.callPhoneAPI(ctx, http.MethodPost, "/api/v1/webhook/configure", map[string]any{
			"endpoint": req.WebhookURL,
			"token":    cfgCopy.WebhookToken,
			"enabled":  true,
		})
		cancel()
		if err == nil && code >= 200 && code < 300 {
			phoneSynced = true
			var m map[string]any
			if json.Unmarshal(respBytes, &m) == nil {
				if apiTok, ok := m["apiToken"].(string); ok && apiTok != "" {
					s.mu.Lock()
					s.config.PhoneApiToken = apiTok
					cfgCopy = s.config
					s.mu.Unlock()
					s.saveState()
				}
			}
		} else {
			syncDetail = fmt.Sprintf("HTTP %d %v %s", code, err, string(respBytes))
		}
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"ok":          true,
		"config":      cfgCopy,
		"phoneSynced": phoneSynced,
		"syncDetail":  syncDetail,
	})
}

func (s *HubServer) handleClearEvents(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "method_not_allowed"})
		return
	}
	s.mu.Lock()
	s.events = nil
	s.chatLog = nil
	s.mu.Unlock()
	s.saveState()
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// --- Windows Clipboard & Desktop Notification Helpers (Pure Go, Zero CGO) ---

func copyToWindowsClipboard(text string) error {
	if runtime.GOOS != "windows" {
		return nil
	}
	if err := setClipboardNative(text); err == nil {
		return nil
	}
	cmd := exec.Command("cmd.exe", "/c", "clip")
	cmd.Stdin = strings.NewReader(text)
	return cmd.Run()
}

func notifyWindowsDesktop(title, message string, sound bool) {
	if runtime.GOOS != "windows" {
		return
	}
	if sound {
		playNativeBeep()
	}
	cleanTitle := strings.ReplaceAll(strings.ReplaceAll(title, "'", " "), "\r\n", " ")
	cleanMsg := strings.ReplaceAll(strings.ReplaceAll(message, "'", " "), "\r\n", " ")
	cleanMsg = strings.ReplaceAll(cleanMsg, "\n", " ")
	cleanMsg = truncateText(cleanMsg, 180)

	psScript := fmt.Sprintf(`
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$n = New-Object System.Windows.Forms.NotifyIcon
$n.Icon = [System.Drawing.SystemIcons]::Information
$n.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
$n.BalloonTipTitle = '%s'
$n.BalloonTipText = '%s'
$n.Visible = $true
$n.ShowBalloonTip(4500)
Start-Sleep -Milliseconds 4700
$n.Dispose()
`, cleanTitle, cleanMsg)
	ctx, cancel := context.WithTimeout(context.Background(), 7*time.Second)
	defer cancel()
	_ = exec.CommandContext(ctx, "powershell.exe", "-NoProfile", "-WindowStyle", "Hidden", "-Command", psScript).Run()
}

// --- Multi-Channel Fan-out Relay (Feishu / DingTalk / WeCom / Bark / Discord / Custom) ---

func (s *HubServer) fanoutEvent(ev WebhookEvent) {
	s.mu.RLock()
	targets := append([]FanoutTarget(nil), s.config.FanoutTargets...)
	s.mu.RUnlock()

	for _, t := range targets {
		if !t.Enabled || strings.TrimSpace(t.Endpoint) == "" {
			continue
		}
		if t.OnlyOTP && ev.OTP == "" {
			continue
		}
		_ = s.sendToFanoutTarget(t, ev)
	}
}

func (s *HubServer) sendToFanoutTarget(t FanoutTarget, ev WebhookEvent) error {
	title := "eSIM-Matrix 事件通知"
	content := ev.Body
	if ev.Event == "sms.received" {
		title = fmt.Sprintf("📩 短信 [%s] (%s)", nonEmpty(ev.Sender, "未知"), nonEmpty(ev.CarrierName, "SIM"))
		if ev.OTP != "" {
			title = fmt.Sprintf("🔑 验证码: %s [%s]", ev.OTP, nonEmpty(ev.Sender, "短信"))
		}
		content = fmt.Sprintf("%s\n\n发件人: %s\n卡槽: SIM %s (%s)\n内容: %s",
			title, nonEmpty(ev.Sender, "-"), formatSlot(ev.SlotIndex), nonEmpty(ev.CarrierName, "-"), ev.Body)
	} else if ev.Event == "call.ringing" {
		title = fmt.Sprintf("📞 来电振铃: %s", ev.Caller)
		content = fmt.Sprintf("📞 收到呼入电话: %s (%s)", ev.Caller, ev.CarrierName)
	} else if ev.Text != "" {
		content = ev.Text
	}

	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()

	switch strings.ToLower(t.Type) {
	case "feishu":
		return s.postJSON(ctx, t.Endpoint, "", map[string]any{
			"msg_type": "text",
			"content":  map[string]any{"text": content},
		})
	case "dingtalk":
		return s.postJSON(ctx, t.Endpoint, "", map[string]any{
			"msgtype": "text",
			"text":    map[string]any{"content": content},
		})
	case "wecom":
		return s.postJSON(ctx, t.Endpoint, "", map[string]any{
			"msgtype": "text",
			"text":    map[string]any{"content": content},
		})
	case "discord":
		return s.postJSON(ctx, t.Endpoint, "", map[string]any{
			"content": content,
		})
	case "bark":
		endpoint := strings.TrimRight(t.Endpoint, "/")
		if !strings.HasSuffix(endpoint, "/push") {
			endpoint += "/push"
		}
		return s.postJSON(ctx, endpoint, "", map[string]any{
			"title": title,
			"body":  nonEmpty(ev.Body, ev.Text),
			"group": "eSIM-Matrix",
		})
	case "command":
		cmd := exec.CommandContext(ctx, "powershell.exe", "-NoProfile", "-Command", t.Endpoint)
		cmd.Env = append(os.Environ(),
			"ESIM_EVENT="+ev.Event,
			"ESIM_SENDER="+ev.Sender,
			"ESIM_OTP="+ev.OTP,
			"ESIM_BODY="+nonEmpty(ev.Body, ev.Text),
		)
		return cmd.Run()
	default: // custom webhook
		return s.postJSON(ctx, t.Endpoint, t.Secret, ev)
	}
}

func (s *HubServer) postJSON(ctx context.Context, urlStr, bearer string, payload any) error {
	b, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, urlStr, bytes.NewReader(b))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json; charset=utf-8")
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	resp, err := s.httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	if resp.StatusCode >= 400 {
		return fmt.Errorf("http_%d", resp.StatusCode)
	}
	return nil
}

// --- ADB One-Click Bridge & Diagnostics Toolbox ---

func (s *HubServer) findADBExecutable() string {
	s.mu.RLock()
	custom := s.config.ADBPath
	s.mu.RUnlock()
	if custom != "" {
		if _, err := os.Stat(custom); err == nil {
			return custom
		}
	}
	if p, err := exec.LookPath("adb"); err == nil {
		return p
	}
	localAppData := os.Getenv("LOCALAPPDATA")
	candidates := []string{
		filepath.Join(localAppData, "Android", "Sdk", "platform-tools", "adb.exe"),
		`C:\Users\chao\AppData\Local\Android\Sdk\platform-tools\adb.exe`,
		`C:\Android\platform-tools\adb.exe`,
	}
	for _, c := range candidates {
		if _, err := os.Stat(c); err == nil {
			return c
		}
	}
	return "adb"
}

type ADBDevice struct {
	Serial  string `json:"serial"`
	State   string `json:"state"`
	Details string `json:"details"`
}

func (s *HubServer) listADBDevices(ctx context.Context) ([]ADBDevice, string, error) {
	adb := s.findADBExecutable()
	out, err := exec.CommandContext(ctx, adb, "devices", "-l").CombinedOutput()
	if err != nil {
		return nil, adb, fmt.Errorf("adb execution failed: %w (%s)", err, string(out))
	}
	lines := strings.Split(string(out), "\n")
	var devs []ADBDevice
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "List of devices") || strings.HasPrefix(line, "*") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) >= 2 {
			devs = append(devs, ADBDevice{
				Serial:  fields[0],
				State:   fields[1],
				Details: strings.Join(fields[2:], " "),
			})
		}
	}
	return devs, adb, nil
}

func (s *HubServer) handleADBStatus(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
	defer cancel()
	devs, adbPath, err := s.listADBDevices(ctx)
	errStr := ""
	if err != nil {
		errStr = err.Error()
	}
	s.mu.RLock()
	bridged := s.adbBridgeActive
	bridgeDev := s.adbBridgeDevice
	s.mu.RUnlock()
	writeJSON(w, http.StatusOK, map[string]any{
		"adbPath":   adbPath,
		"devices":   devs,
		"error":     errStr,
		"bridged":   bridged,
		"bridgeDev": bridgeDev,
	})
}

// handleADBBridge sets up:
// 1. `adb -s <serial> forward tcp:18787 tcp:8787` (Windows -> Phone Gateway)
// 2. `adb -s <serial> reverse tcp:9787 tcp:9787` (Phone Webhook -> Windows :9787)
// 3. Configures the phone's webhook to `http://127.0.0.1:9787/webhook` and syncs tokens!
func (s *HubServer) handleADBBridge(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "method_not_allowed"})
		return
	}
	var req struct {
		Serial      string `json:"serial"`
		ConnectAddr string `json:"connectAddr"`
	}
	_ = json.NewDecoder(io.LimitReader(r.Body, 16*1024)).Decode(&req)

	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	adb := s.findADBExecutable()

	if strings.TrimSpace(req.ConnectAddr) != "" {
		_, _ = exec.CommandContext(ctx, adb, "connect", strings.TrimSpace(req.ConnectAddr)).CombinedOutput()
	}

	devs, _, err := s.listADBDevices(ctx)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	serial := strings.TrimSpace(req.Serial)
	if serial == "" {
		for _, d := range devs {
			if d.State == "device" {
				serial = d.Serial
				break
			}
		}
	}
	if serial == "" {
		writeJSON(w, http.StatusNotFound, map[string]any{
			"ok":    false,
			"error": "未检测到在线的 ADB 手机，请插入 USB 数据线或连接无线调试。",
		})
		return
	}

	port := defaultPort
	s.mu.RLock()
	if _, pStr, err := net.SplitHostPort(s.config.ListenAddr); err == nil {
		_, _ = fmt.Sscanf(pStr, "%d", &port)
	}
	whToken := s.config.WebhookToken
	s.mu.RUnlock()

	fwdOut, fwdErr := exec.CommandContext(ctx, adb, "-s", serial, "forward", "tcp:18787", "tcp:8787").CombinedOutput()
	revOut, revErr := exec.CommandContext(ctx, adb, "-s", serial, "reverse", fmt.Sprintf("tcp:%d", port), fmt.Sprintf("tcp:%d", port)).CombinedOutput()
	if fwdErr != nil || revErr != nil {
		if fwdErr == nil {
			// Leaving the forward behind squats on 18787 and hides the failure.
			_, _ = exec.CommandContext(ctx, adb, "-s", serial, "forward", "--remove", "tcp:18787").CombinedOutput()
		}
		s.mu.Lock()
		s.adbBridgeActive = false
		s.adbBridgeDevice = ""
		s.mu.Unlock()
		writeJSON(w, http.StatusInternalServerError, map[string]any{
			"ok":    false,
			"error": fmt.Sprintf("ADB 隧道建立失败: forward=%v (%s), reverse=%v (%s)", fwdErr, string(fwdOut), revErr, string(revOut)),
		})
		return
	}

	// Ensure the app/gateway is awake on the phone.
	_, _ = exec.CommandContext(ctx, adb, "-s", serial, "shell", "am", "start", "-n", "io.github.hg552.esimmatrix.multi/io.github.hg552.esimmatrix.MainActivity").CombinedOutput()

	s.mu.Lock()
	s.config.PhoneGatewayURL = "http://127.0.0.1:18787"
	s.adbBridgeActive = true
	s.adbBridgeDevice = serial
	s.mu.Unlock()
	s.saveState()

	// Auto-configure the phone's webhook via /api/v1/webhook/configure over ADB loopback.
	webhookTarget := fmt.Sprintf("http://127.0.0.1:%d/webhook", port)
	cfgBody, _ := json.Marshal(map[string]any{
		"endpoint": webhookTarget,
		"token":    whToken,
		"enabled":  true,
	})
	var code int
	var respBytes []byte
	var callErr error
	if cfgReq, reqErr := http.NewRequestWithContext(ctx, http.MethodPost, "http://127.0.0.1:18787/api/v1/webhook/configure", bytes.NewReader(cfgBody)); reqErr == nil {
		cfgReq.Header.Set("Content-Type", "application/json; charset=utf-8")
		cfgReq.Header.Set("X-Adb-Bootstrap", "1")
		if tok := s.getPhoneBearerToken(); tok != "" {
			cfgReq.Header.Set("Authorization", "Bearer "+tok)
		}
		if resp, doErr := s.httpClient.Do(cfgReq); doErr == nil {
			code = resp.StatusCode
			respBytes, _ = io.ReadAll(io.LimitReader(resp.Body, 64*1024))
			resp.Body.Close()
			var m map[string]any
			if json.Unmarshal(respBytes, &m) == nil {
				if apiTok, ok := m["apiToken"].(string); ok && apiTok != "" {
					s.mu.Lock()
					s.config.PhoneApiToken = apiTok
					s.phoneReachable = true
					s.phoneLastSeen = time.Now().UnixMilli()
					s.mu.Unlock()
					s.saveState()
				}
			}
		} else {
			callErr = doErr
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":              true,
		"serial":          serial,
		"phoneGatewayUrl": "http://127.0.0.1:18787",
		"webhookUrl":      webhookTarget,
		"webhookToken":    whToken,
		"autoConfigured":  callErr == nil && code >= 200 && code < 300,
		"configureStatus": code,
		"configureReply":  string(respBytes),
	})
}

func (s *HubServer) handleADBLogcat(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	devs, adb, err := s.listADBDevices(ctx)
	if err != nil || len(devs) == 0 {
		writeJSON(w, http.StatusNotFound, map[string]any{"ok": false, "error": "未连接 ADB 设备"})
		return
	}
	serial := devs[0].Serial
	out, err := exec.CommandContext(ctx, adb, "-s", serial, "logcat", "-d", "-t", "200").CombinedOutput()
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	var filtered []string
	keywords := []string{"flutter", "esimmatrix", "Omapi", "Qrtr", "SmsRelay", "MockLocation", "NexusDataGuard", "NetworkStatus"}
	for _, line := range strings.Split(string(out), "\n") {
		for _, kw := range keywords {
			if strings.Contains(line, kw) {
				filtered = append(filtered, strings.TrimRight(line, "\r"))
				break
			}
		}
	}
	if len(filtered) == 0 {
		lines := strings.Split(string(out), "\n")
		if len(lines) > 80 {
			lines = lines[len(lines)-80:]
		}
		filtered = lines
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":     true,
		"serial": serial,
		"lines":  filtered,
	})
}

// --- Toolbox: LPA Parser, Clipboard, Toast, Simulate SMS, Fanout Test ---

func (s *HubServer) handleLPAParse(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Code string `json:"code"`
	}
	_ = json.NewDecoder(io.LimitReader(r.Body, 16*1024)).Decode(&req)
	parsed := parseLPACode(req.Code)
	writeJSON(w, http.StatusOK, parsed)
}

func (s *HubServer) handleLPAVoucherSVG(w http.ResponseWriter, r *http.Request) {
	code := r.URL.Query().Get("code")
	svg := renderLPACardSVG(code)
	w.Header().Set("Content-Type", "image/svg+xml; charset=utf-8")
	_, _ = w.Write([]byte(svg))
}

func (s *HubServer) handleClipboardCopy(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Text string `json:"text"`
	}
	_ = json.NewDecoder(io.LimitReader(r.Body, 32*1024)).Decode(&req)
	err := copyToWindowsClipboard(req.Text)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *HubServer) handleSimulateSMS(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Sender  string `json:"sender"`
		Body    string `json:"body"`
		Carrier string `json:"carrier"`
	}
	_ = json.NewDecoder(io.LimitReader(r.Body, 16*1024)).Decode(&req)
	if req.Sender == "" {
		req.Sender = "Google"
	}
	if req.Body == "" {
		req.Body = fmt.Sprintf("G-%06d is your Google verification code. Do not share it with anyone.", time.Now().Unix()%1000000)
	}
	if req.Carrier == "" {
		req.Carrier = "Club Sim HK"
	}
	slot := 1
	payload, _ := json.Marshal(WebhookEvent{
		Event:                 "sms.received",
		MessageID:             fmt.Sprintf("sim_%d", time.Now().UnixNano()),
		Sender:                req.Sender,
		Body:                  req.Body,
		OTP:                   extractOTP(req.Body),
		SlotIndex:             &slot,
		CarrierName:           req.Carrier,
		ReceivedAtEpochMillis: time.Now().UnixMilli(),
	})
	simReq, _ := http.NewRequest(http.MethodPost, "/webhook", bytes.NewReader(payload))
	simReq.RemoteAddr = "127.0.0.1:0"
	simReq.Header.Set("X-Hub-Simulated", "1")
	s.mu.RLock()
	simReq.Header.Set("Authorization", "Bearer "+s.config.WebhookToken)
	s.mu.RUnlock()
	s.handleWebhook(w, simReq)
}

func (s *HubServer) handleFanoutTest(w http.ResponseWriter, r *http.Request) {
	slot := 1
	ev := WebhookEvent{
		Event:                 "sms.received",
		Sender:                "eSIM-Matrix 二传手测试",
		Body:                  "【eSIM-Matrix】多渠道二传手测试成功！示例验证码：888999。",
		OTP:                   "888999",
		SlotIndex:             &slot,
		CarrierName:           "eSIM-Hub Windows",
		ReceivedAtEpochMillis: time.Now().UnixMilli(),
	}
	go s.fanoutEvent(ev)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *HubServer) routes() http.Handler {
	mux := http.NewServeMux()

	// Webhook ingestion routes (compatible with both Webhook mode and CF Worker /api/push)
	mux.HandleFunc("/webhook", s.handleWebhook)
	mux.HandleFunc("/api/push", s.handleWebhook)
	mux.HandleFunc("/api/v1/webhook", s.handleWebhook)

	// Local Hub APIs
	mux.HandleFunc("/api/local/state", s.handleLocalState)
	mux.HandleFunc("/api/local/config", s.handleSaveConfig)
	mux.HandleFunc("/api/local/clear", s.handleClearEvents)
	mux.HandleFunc("/api/local/events", s.handleSSE)
	mux.HandleFunc("/api/local/bot", s.handleLocalBot)
	mux.HandleFunc("/api/local/otp/latest", s.handleLatestOTP)
	mux.HandleFunc("/api/local/switch-and-wait-otp", s.handleSwitchAndWaitOTP)

	// Toolbox APIs
	mux.HandleFunc("/api/tools/adb/status", s.handleADBStatus)
	mux.HandleFunc("/api/tools/adb/bridge", s.handleADBBridge)
	mux.HandleFunc("/api/tools/adb/logcat", s.handleADBLogcat)
	mux.HandleFunc("/api/tools/lpa/parse", s.handleLPAParse)
	mux.HandleFunc("/api/tools/lpa/voucher.svg", s.handleLPAVoucherSVG)
	mux.HandleFunc("/api/tools/clipboard", s.handleClipboardCopy)
	mux.HandleFunc("/api/tools/simulate-sms", s.handleSimulateSMS)
	mux.HandleFunc("/api/tools/fanout/test", s.handleFanoutTest)

	// Transparent Phone Gateway Proxy (/api/phone/* -> <PhoneGatewayURL>/api/v1/*)
	mux.HandleFunc("/api/phone/", s.handlePhoneProxy)

	// Embedded Single-Page Web Console
	webFS, _ := fs.Sub(embeddedWeb, "web")
	fileServer := http.FileServer(http.FS(webFS))
	mux.Handle("/", fileServer)

	return mux
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func nonEmpty(val, fallback string) string {
	if strings.TrimSpace(val) == "" {
		return fallback
	}
	return val
}

func formatSlot(slot *int) string {
	if slot == nil {
		return "?"
	}
	return fmt.Sprintf("%d", *slot+1)
}

func truncateText(s string, maxLen int) string {
	runes := []rune(s)
	if len(runes) <= maxLen {
		return s
	}
	return string(runes[:maxLen]) + "..."
}

func openBrowser(url string) {
	if runtime.GOOS == "windows" {
		_ = exec.Command("rundll32", "url.dll,FileProtocolHandler", url).Start()
	}
}

// --- CLI Subcommand Runner ---

func runCLICommand(hubURL string, args []string) int {
	sub := strings.ToLower(args[0])
	rest := args[1:]
	client := &http.Client{Timeout: 130 * time.Second}

	switch sub {
	case "otp":
		waitSec := 0
		sender := ""
		for i := 0; i < len(rest); i++ {
			if rest[i] == "--wait" && i+1 < len(rest) {
				_, _ = fmt.Sscanf(rest[i+1], "%d", &waitSec)
				i++
			} else if rest[i] == "--sender" && i+1 < len(rest) {
				sender = rest[i+1]
				i++
			}
		}
		u := fmt.Sprintf("%s/api/local/otp/latest?wait=%d&sender=%s", hubURL, waitSec, sender)
		resp, err := client.Get(u)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			return 1
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		fmt.Println(string(b))
		if resp.StatusCode >= 400 {
			return 1
		}
		return 0

	case "switch-otp":
		if len(rest) == 0 {
			fmt.Fprintln(os.Stderr, "Usage: esim-hub.exe switch-otp <profile> [--timeout 120] [--sender Google]")
			return 1
		}
		profile := rest[0]
		timeoutSec := 120
		sender := ""
		for i := 1; i < len(rest); i++ {
			if rest[i] == "--timeout" && i+1 < len(rest) {
				_, _ = fmt.Sscanf(rest[i+1], "%d", &timeoutSec)
				i++
			} else if rest[i] == "--sender" && i+1 < len(rest) {
				sender = rest[i+1]
				i++
			}
		}
		payload, _ := json.Marshal(map[string]any{
			"profile":        profile,
			"timeoutSeconds": timeoutSec,
			"senderContains": sender,
			"autoBack":       true,
		})
		resp, err := client.Post(hubURL+"/api/local/switch-and-wait-otp", "application/json", bytes.NewReader(payload))
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			return 1
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		fmt.Println(string(b))
		if resp.StatusCode >= 400 {
			return 1
		}
		return 0

	case "adb-bridge":
		resp, err := client.Post(hubURL+"/api/tools/adb/bridge", "application/json", strings.NewReader("{}"))
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			return 1
		}
		defer resp.Body.Close()
		b, _ := io.ReadAll(resp.Body)
		fmt.Println(string(b))
		return 0

	default:
		// Treat as a Telegram Bot slash command!
		slashCmd := "/" + strings.TrimPrefix(sub, "/")
		if sub == "bot" && len(rest) > 0 {
			slashCmd = strings.Join(rest, " ")
		} else if len(rest) > 0 {
			slashCmd += " " + strings.Join(rest, " ")
		}
		payload, _ := json.Marshal(map[string]any{"text": slashCmd})
		resp, err := client.Post(hubURL+"/api/local/bot", "application/json", bytes.NewReader(payload))
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error connecting to local esim-hub (%s): %v\n", hubURL, err)
			return 1
		}
		defer resp.Body.Close()
		var out struct {
			OK    bool      `json:"ok"`
			Reply ChatEntry `json:"reply"`
		}
		b, _ := io.ReadAll(resp.Body)
		if json.Unmarshal(b, &out) == nil && out.Reply.Text != "" {
			fmt.Println(out.Reply.Text)
			if len(out.Reply.Keyboard) > 0 {
				fmt.Println("\n--- 可用快捷动作 ---")
				for _, row := range out.Reply.Keyboard {
					var labels []string
					for _, btn := range row {
						labels = append(labels, fmt.Sprintf("[%s (%s)]", btn.Text, btn.CallbackData))
					}
					fmt.Println(strings.Join(labels, "  "))
				}
			}
			return 0
		}
		fmt.Println(string(b))
		return 0
	}
}

func main() {
	runtime.LockOSThread()
	stateFile := defaultStatePath()
	args := os.Args[1:]

	if len(args) > 0 && args[0] != "serve" && !strings.HasPrefix(args[0], "-") {
		attachParentConsoleIfCLI()
		if args[0] == "help" || args[0] == "--help" || args[0] == "-h" {
			printCLIHelp()
			return
		}
		os.Exit(runCLICommand(fmt.Sprintf("http://127.0.0.1:%d", defaultPort), args))
	}

	for _, a := range args {
		if a == "--help" || a == "-h" {
			attachParentConsoleIfCLI()
			printCLIHelp()
			return
		}
	}

	if len(args) > 0 && args[0] == "serve" {
		args = args[1:]
	}
	fsFlags := flag.NewFlagSet("serve", flag.ContinueOnError)
	listenFlag := fsFlags.String("listen", "", "Listen address (default 0.0.0.0:9787)")
	phoneFlag := fsFlags.String("phone", "", "Phone gateway URL (e.g. http://192.168.1.17:8787)")
	tokenFlag := fsFlags.String("token", "", "Shared Webhook / Gateway Bearer Token")
	noBrowser := fsFlags.Bool("no-browser", false, "Run headless server without opening GUI window")
	headless := fsFlags.Bool("headless", false, "Run headless server without opening GUI window")
	useBrowser := fsFlags.Bool("browser", false, "Open in external web browser instead of native window")
	_ = fsFlags.Parse(args)

	isHeadless := *noBrowser || *headless
	if isHeadless {
		attachParentConsoleIfCLI()
	}

	hub := NewHubServer(stateFile)
	hub.mu.Lock()
	if *listenFlag != "" {
		hub.config.ListenAddr = *listenFlag
	}
	if *phoneFlag != "" {
		hub.config.PhoneGatewayURL = strings.TrimRight(*phoneFlag, "/")
	}
	if *tokenFlag != "" {
		hub.config.WebhookToken = *tokenFlag
	}
	listenAddr := hub.config.ListenAddr
	hub.mu.Unlock()
	hub.saveState()

	_, portStr, err := net.SplitHostPort(listenAddr)
	if err != nil {
		portStr = "9787"
	}
	localURL := fmt.Sprintf("http://127.0.0.1:%s", portStr)

	srv := &http.Server{
		Addr:              listenAddr,
		Handler:           hub.routes(),
		ReadHeaderTimeout: 10 * time.Second,
	}

	ln, listenErr := net.Listen("tcp", listenAddr)
	if listenErr == nil {
		go func() {
			if sErr := srv.Serve(ln); sErr != nil && !errors.Is(sErr, http.ErrServerClosed) {
				log.Printf("HTTP server error: %v", sErr)
			}
		}()
	} else if isHeadless {
		log.Fatalf("Listen failed on %s: %v", listenAddr, listenErr)
	}

	if isHeadless {
		select {}
	}

	if !guiSupported {
		// A server build has no window host: the console is the HTTP endpoint.
		fmt.Printf("🌐 Web 控制台已就绪: %s\n", localURL)
		for _, ip := range listLocalIPv4s() {
			fmt.Printf("📡 手机 Webhook 地址: http://%s:%s/webhook\n", ip, portStr)
		}
		select {}
	}

	if *useBrowser {
		openBrowser(localURL)
		select {}
	}

	// Default: open native Win32 desktop window embedding WebView2!
	if guiErr := runNativeGUIWindow(localURL); guiErr != nil {
		// Fallback to browser only if WebView2 runtime is missing on an older system.
		openBrowser(localURL)
		select {}
	}
	_ = srv.Close()
}

func whTokenPreview(tok string) string {
	if len(tok) <= 8 {
		return tok
	}
	return tok
}

func printCLIHelp() {
	fmt.Println(`eSIM-Matrix Windows Hub (esim-hub.exe) — 手机 Webhook 接收 + TG Bot 全指令控制台 + 自动化 API

用法:
  esim-hub.exe [serve] [--listen 0.0.0.0:9787] [--phone http://192.168.1.17:8787] [--no-browser]
  esim-hub.exe <TG_Bot_指令> [参数...]

常用 CLI 子命令 (与手机 TG Bot 100% 同步):
  esim-hub.exe status                       查看双卡基带漫游、信号 dBm、电量温度与芯片空间
  esim-hub.exe list                         列出卡内所有 eSIM Profile 与快捷操作
  esim-hub.exe use <序号或名称>              持久切换到指定 eSIM 卡位
  esim-hub.exe use_temp <序号或名称>         临时切卡 5 分钟接码，到期自动切回默认主卡
  esim-hub.exe back                         立即切回默认常驻主卡
  esim-hub.exe default                      将当前激活卡设为默认主卡
  esim-hub.exe kick                         快速刷新基带重搜网
  esim-hub.exe keepalive                    查看和管理定时自动切卡保号规则
  esim-hub.exe readers                      查看或切换物理卡槽/读卡器 (SIM 1 / SIM 2)
  esim-hub.exe location <纬度> <经度> [备注]  注入虚拟定位 (Shizuku / 开发者模式)
  esim-hub.exe location_stop                停止虚拟定位，恢复真实 GPS
  esim-hub.exe proxy                        查看或切换 FlClash / Mihomo 代理节点
  esim-hub.exe guard                        查看漫游流量护盾状态
  esim-hub.exe guard_toggle                 一键开关漫游流量护盾
  esim-hub.exe download <LPA:1$...>         远程空中下载 eSIM
  esim-hub.exe download_test                一键下载 Speedtest 公开测试卡
  esim-hub.exe delete <序号>                安全两步删卡
  esim-hub.exe retry_sms                    一键补发手机端未送达短信

本地高阶自动化子命令:
  esim-hub.exe otp [--wait 60] [--sender X] 立即读取或阻塞等待最新短信验证码
  esim-hub.exe switch-otp <卡名> [--timeout 120] 一键完成「切卡 -> 等网 -> 等验证码 -> 切回主卡」
  esim-hub.exe adb-bridge                   一键通过 USB/无线 ADB 建立双向免配隧道`)
}
