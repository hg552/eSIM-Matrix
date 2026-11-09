package main

import (
	"fmt"
	"html"
	"regexp"
	"strings"
)

// ParsedLPA represents a decoded GSMA SGP.22 Activation Code (LPA:1$smdp$matchingId...).
type ParsedLPA struct {
	Raw                      string `json:"raw"`
	Valid                    bool   `json:"valid"`
	Format                   string `json:"format"`
	SMDPAddress              string `json:"smdpAddress"`
	MatchingID               string `json:"matchingId"`
	OID                      string `json:"oid,omitempty"`
	ConfirmationCodeRequired bool   `json:"confirmationCodeRequired"`
	Error                    string `json:"error,omitempty"`
}

func parseLPACode(raw string) ParsedLPA {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return ParsedLPA{Raw: raw, Valid: false, Error: "激活码为空"}
	}
	upper := strings.ToUpper(trimmed)
	if !strings.HasPrefix(upper, "LPA:") {
		// Allow shorthand "smdp$matchingId" and normalize to LPA:1$...
		if strings.Contains(trimmed, "$") {
			trimmed = "LPA:1$" + strings.TrimPrefix(trimmed, "$")
		} else {
			return ParsedLPA{Raw: raw, Valid: false, Error: "必须以 LPA:1$ 开头"}
		}
	}
	parts := strings.Split(trimmed, "$")
	if len(parts) < 3 {
		return ParsedLPA{Raw: trimmed, Valid: false, Error: "缺少 SM-DP+ 地址或 Matching ID 分隔符 ($)"}
	}
	format := parts[0]
	smdp := strings.TrimSpace(parts[1])
	matchingID := strings.TrimSpace(parts[2])
	if smdp == "" || !strings.Contains(smdp, ".") {
		return ParsedLPA{Raw: trimmed, Valid: false, Error: "SM-DP+ 域名无效"}
	}
	if matchingID == "" {
		// SGP.22 requires a matching ID; an empty one only fails later on the phone.
		return ParsedLPA{Raw: trimmed, Valid: false, Error: "缺少 Matching ID"}
	}
	var oid string
	if len(parts) > 3 {
		oid = strings.TrimSpace(parts[3])
	}
	ccReq := false
	if len(parts) > 4 {
		v := strings.TrimSpace(parts[4])
		ccReq = v == "1" || strings.EqualFold(v, "true")
	}
	return ParsedLPA{
		Raw:                      trimmed,
		Valid:                    true,
		Format:                   format,
		SMDPAddress:              smdp,
		MatchingID:               matchingID,
		OID:                      oid,
		ConfirmationCodeRequired: ccReq,
	}
}

// PresetLocation represents a built-in base station / roaming coordinate preset.
type PresetLocation struct {
	ID      string  `json:"id"`
	Region  string  `json:"region"`
	Label   string  `json:"label"`
	Carrier string  `json:"carrier"`
	MCCMNC  string  `json:"mccMnc"`
	Lat     float64 `json:"latitude"`
	Lng     float64 `json:"longitude"`
}

var defaultPresetLocations = []PresetLocation{
	{ID: "hk-tst", Region: "香港", Label: "香港 尖沙咀 (Club Sim / HKT / 3HK)", Carrier: "CSL / 3HK / CMHK", MCCMNC: "454/00, 454/03", Lat: 22.2988, Lng: 114.1722},
	{ID: "hk-central", Region: "香港", Label: "香港 中环 IFC", Carrier: "CSL / SmarTone", MCCMNC: "454/00, 454/06", Lat: 22.2855, Lng: 114.1577},
	{ID: "us-ny", Region: "美国", Label: "美国 纽约曼哈顿 (T-Mobile / AT&T)", Carrier: "T-Mobile US / AT&T", MCCMNC: "310/260, 310/410", Lat: 40.7580, Lng: -73.9855},
	{ID: "us-sf", Region: "美国", Label: "美国 旧金山湾区 (Verizon / T-Mobile)", Carrier: "T-Mobile / Verizon", MCCMNC: "310/260, 311/480", Lat: 37.7749, Lng: -122.4194},
	{ID: "uk-lon", Region: "英国", Label: "英国 伦敦威斯敏斯特 (giffgaff / Vodafone / EE)", Carrier: "O2 / Vodafone / EE", MCCMNC: "234/10, 234/15, 234/30", Lat: 51.5074, Lng: -0.1278},
	{ID: "ee-tll", Region: "爱沙尼亚", Label: "爱沙尼亚 塔林老城 (Elisa EE / Telia)", Carrier: "Elisa EE / Telia", MCCMNC: "248/02, 248/01", Lat: 59.4370, Lng: 24.7536},
	{ID: "jp-tyo", Region: "日本", Label: "日本 东京新宿 (SoftBank / Docomo / KDDI)", Carrier: "SoftBank / NTT Docomo", MCCMNC: "440/20, 440/10", Lat: 35.6895, Lng: 139.6917},
	{ID: "fr-par", Region: "法国", Label: "法国 巴黎歌剧院 (Orange / Free / Saily)", Carrier: "Orange F / Bouygues", MCCMNC: "208/01, 208/20", Lat: 48.8719, Lng: 2.3316},
	{ID: "sg-mb", Region: "新加坡", Label: "新加坡 滨海湾 (Singtel / StarHub)", Carrier: "Singtel / StarHub", MCCMNC: "525/01, 525/05", Lat: 1.2834, Lng: 103.8607},
	{ID: "de-fra", Region: "德国", Label: "德国 法兰克福 (Telekom / Vodafone DE)", Carrier: "Telekom.de / O2 DE", MCCMNC: "262/01, 262/02", Lat: 50.1109, Lng: 8.6821},
}

// xmlIllegal matches the characters XML 1.0 forbids anywhere in a document.
var xmlIllegal = regexp.MustCompile(`[\x00-\x08\x0B\x0C\x0E-\x1F]`)

// renderLPACardSVG creates a clean printable SVG card with the LPA text and visual matrix badge.
func renderLPACardSVG(lpa string) string {
	parsed := parseLPACode(lpa)
	// html.EscapeString covers markup, not the control range: one stray 0x01 makes
	// the whole document unparseable and the <img> renders as a broken icon.
	escapedRaw := html.EscapeString(xmlIllegal.ReplaceAllString(parsed.Raw, ""))
	escapedSMDP := html.EscapeString(xmlIllegal.ReplaceAllString(parsed.SMDPAddress, ""))
	escapedMatch := html.EscapeString(xmlIllegal.ReplaceAllString(parsed.MatchingID, ""))
	return fmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 680 220" width="680" height="220">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%%" stop-color="#0f172a"/>
      <stop offset="100%%" stop-color="#1e293b"/>
    </linearGradient>
  </defs>
  <rect width="680" height="220" rx="20" fill="url(#bg)" stroke="#38bdf8" stroke-opacity="0.4" stroke-width="2"/>
  <text x="28" y="42" fill="#38bdf8" font-family="Segoe UI, sans-serif" font-size="18" font-weight="bold">eSIM-Matrix · GSMA SGP.22 Activation Voucher</text>
  <text x="28" y="78" fill="#94a3b8" font-family="Segoe UI, sans-serif" font-size="13">SM-DP+ Address</text>
  <text x="28" y="100" fill="#f8fafc" font-family="Consolas, monospace" font-size="16" font-weight="bold">%s</text>
  <text x="28" y="132" fill="#94a3b8" font-family="Segoe UI, sans-serif" font-size="13">Matching ID / Activation Token</text>
  <text x="28" y="154" fill="#22d3ee" font-family="Consolas, monospace" font-size="16" font-weight="bold">%s</text>
  <text x="28" y="192" fill="#64748b" font-family="Consolas, monospace" font-size="12">%s</text>
</svg>`, escapedSMDP, escapedMatch, escapedRaw)
}
