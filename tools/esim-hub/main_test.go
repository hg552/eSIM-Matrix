package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"
)

func TestWebhookAndOTPWaiter(t *testing.T) {
	tmpState := filepath.Join(t.TempDir(), "state.json")
	hub := NewHubServer(tmpState)
	hub.config.AutoCopyOTP = false
	hub.config.DesktopNotify = false
	handler := hub.routes()

	// 1. Start a long-polling OTP waiter in background
	otpDone := make(chan string, 1)
	go func() {
		req := httptest.NewRequest(http.MethodGet, "/api/local/otp/latest?wait=5&onlyNew=1&sender=Google", nil)
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, req)
		var resp struct {
			OK  bool   `json:"ok"`
			OTP string `json:"otp"`
		}
		_ = json.Unmarshal(w.Body.Bytes(), &resp)
		otpDone <- resp.OTP
	}()

	time.Sleep(80 * time.Millisecond)

	// 2. Queue a reverse bot command while phone is offline
	botReq := httptest.NewRequest(http.MethodPost, "/api/local/bot", bytes.NewBufferString(`{"text":"/status"}`))
	botW := httptest.NewRecorder()
	handler.ServeHTTP(botW, botReq)

	// 3. Post an incoming SMS webhook from the phone
	smsPayload := `{"event":"sms.received","sender":"Google","body":"Your Google verification code is 948271.","carrierName":"Club Sim","slotIndex":1}`
	whReq := httptest.NewRequest(http.MethodPost, "/webhook", bytes.NewBufferString(smsPayload))
	whW := httptest.NewRecorder()
	handler.ServeHTTP(whW, whReq)
	if whW.Code != http.StatusOK {
		t.Fatalf("unexpected webhook status: %d", whW.Code)
	}

	var whResp struct {
		OK              bool             `json:"ok"`
		PendingCommands []PendingCommand `json:"pendingCommands"`
	}
	if err := json.Unmarshal(whW.Body.Bytes(), &whResp); err != nil {
		t.Fatalf("unmarshal webhook response: %v", err)
	}
	if len(whResp.PendingCommands) != 1 || whResp.PendingCommands[0].Text != "/status" {
		t.Fatalf("expected queued /status command in webhook response, got %+v", whResp.PendingCommands)
	}

	select {
	case gotOTP := <-otpDone:
		if gotOTP != "948271" {
			t.Fatalf("expected OTP 948271, got %q", gotOTP)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for long-polling OTP")
	}

	// The saver runs in the background; give it a beat so TempDir cleanup does
	// not race a state write.
	time.Sleep(300 * time.Millisecond)
}

func TestParseLPACode(t *testing.T) {
	p := parseLPACode("LPA:1$rsp.truphone.com$QRF-SPEEDTEST")
	if !p.Valid || p.SMDPAddress != "rsp.truphone.com" || p.MatchingID != "QRF-SPEEDTEST" {
		t.Fatalf("unexpected parsed LPA: %+v", p)
	}
}
