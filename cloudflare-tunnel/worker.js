/**
 * eUICC-Nexus Cloudflare Worker End-to-End Encrypted SMS Tunnel & Live Web Dashboard
 *
 * Zero-Knowledge Architecture:
 * - Phone encrypts SMS payload locally with AES-256-GCM.
 * - Cloudflare Worker only relays and caches ciphertext.
 * - Browser decrypts client-side using the secret in URL fragment (#key=...).
 * - The encryption key never reaches Cloudflare's servers.
 */

// In-memory SSE clients set per channel (POP-local)
const sseClients = new Map();

addEventListener('fetch', event => {
  event.respondWith(handleRequest(event.request, event));
});

async function handleRequest(request, event) {
  const url = new URL(request.url);
  const path = url.pathname;

  // CORS Headers
  const corsHeaders = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, X-Channel-Id, X-Channel-Token',
  };

  if (request.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    if (path === '/api/push' && request.method === 'POST') {
      return await handlePush(request, corsHeaders);
    }
    if (path === '/api/heartbeat' && request.method === 'POST') {
      return await handleHeartbeat(request, corsHeaders);
    }
    if (path === '/api/poll' && request.method === 'GET') {
      return await handlePoll(request, url, corsHeaders);
    }
    if (path === '/api/stream' && request.method === 'GET') {
      return handleStream(request, url);
    }
    if (path === '/api/health') {
      return new Response(JSON.stringify({ status: 'ok', time: Date.now() }), {
        headers: { 'Content-Type': 'application/json', ...corsHeaders },
      });
    }

    // Default: Serve Web Dashboard
    return new Response(renderDashboardHtml(), {
      headers: {
        'Content-Type': 'text/html; charset=utf-8',
        'Cache-Control': 'no-cache',
      },
    });
  } catch (err) {
    return new Response(JSON.stringify({ error: err.message || 'internal_error' }), {
      status: 500,
      headers: { 'Content-Type': 'application/json', ...corsHeaders },
    });
  }
}

// -----------------------------------------------------------------------------
// API Handlers
// -----------------------------------------------------------------------------

async function verifyAuth(channelId, token) {
  if (!channelId || !token) return false;
  if (!/^[a-zA-Z0-9_-]{4,64}$/.test(channelId)) return false;
  if (!/^[a-fA-F0-9]{64}$/.test(token)) return false;

  if (typeof SMS_KV !== 'undefined') {
    const authKey = `auth:${channelId}`;
    const stored = await SMS_KV.get(authKey);
    if (!stored) {
      // First registration binds this channel to the token
      await SMS_KV.put(authKey, token, { expirationTtl: 86400 * 30 });
      return true;
    }
    return stored.toLowerCase() === token.toLowerCase();
  }
  return true;
}

async function handlePush(request, corsHeaders) {
  const channelId = request.headers.get('X-Channel-Id');
  const token = request.headers.get('X-Channel-Token');

  if (!channelId || !token) {
    return new Response(JSON.stringify({ error: 'missing_auth_headers' }), {
      status: 401,
      headers: { 'Content-Type': 'application/json', ...corsHeaders },
    });
  }

  const authed = await verifyAuth(channelId, token);
  if (!authed) {
    return new Response(JSON.stringify({ error: 'unauthorized_channel' }), {
      status: 403,
      headers: { 'Content-Type': 'application/json', ...corsHeaders },
    });
  }

  const body = await request.json();
  const id = body.id || `msg_${Date.now()}_${Math.random().toString(36).substring(2, 8)}`;
  const item = {
    id: id,
    iv: body.iv,
    ciphertext: body.ciphertext,
    timestamp: body.timestamp || Date.now(),
  };

  if (!item.iv || !item.ciphertext) {
    return new Response(JSON.stringify({ error: 'invalid_payload' }), {
      status: 400,
      headers: { 'Content-Type': 'application/json', ...corsHeaders },
    });
  }

  if (typeof SMS_KV !== 'undefined') {
    // 1. Save message item
    await SMS_KV.put(`msg:${channelId}:${id}`, JSON.stringify(item), { expirationTtl: 86400 * 7 });

    // 2. Update channel index (limit to last 50)
    const idxKey = `idx:${channelId}`;
    let idx = await SMS_KV.get(idxKey, 'json');
    if (!Array.isArray(idx)) idx = [];
    idx.unshift(id);
    if (idx.length > 50) idx = idx.slice(0, 50);
    await SMS_KV.put(idxKey, JSON.stringify(idx), { expirationTtl: 86400 * 7 });
  }

  // 3. Broadcast to local SSE clients
  broadcastSSE(channelId, { type: 'sms', item });

  return new Response(JSON.stringify({ success: true, id }), {
    headers: { 'Content-Type': 'application/json', ...corsHeaders },
  });
}

async function handleHeartbeat(request, corsHeaders) {
  const channelId = request.headers.get('X-Channel-Id');
  const token = request.headers.get('X-Channel-Token');

  if (!channelId || !token) {
    return new Response(JSON.stringify({ error: 'missing_auth_headers' }), {
      status: 401,
      headers: { 'Content-Type': 'application/json', ...corsHeaders },
    });
  }

  const authed = await verifyAuth(channelId, token);
  if (!authed) {
    return new Response(JSON.stringify({ error: 'unauthorized_channel' }), {
      status: 403,
      headers: { 'Content-Type': 'application/json', ...corsHeaders },
    });
  }

  const payload = await request.json();
  const hbData = {
    iv: payload.iv,
    ciphertext: payload.ciphertext,
    timestamp: payload.timestamp || Date.now(),
  };

  if (typeof SMS_KV !== 'undefined') {
    await SMS_KV.put(`hb:${channelId}`, JSON.stringify(hbData), { expirationTtl: 3600 });
  }

  broadcastSSE(channelId, { type: 'heartbeat', data: hbData });

  return new Response(JSON.stringify({ success: true }), {
    headers: { 'Content-Type': 'application/json', ...corsHeaders },
  });
}

async function handlePoll(request, url, corsHeaders) {
  const channelId = url.searchParams.get('channel');
  const token = url.searchParams.get('token');
  const since = parseInt(url.searchParams.get('since') || '0', 10);

  if (!channelId || !token) {
    return new Response(JSON.stringify({ error: 'missing_params' }), {
      status: 400,
      headers: { 'Content-Type': 'application/json', ...corsHeaders },
    });
  }

  const authed = await verifyAuth(channelId, token);
  if (!authed) {
    return new Response(JSON.stringify({ error: 'unauthorized_channel' }), {
      status: 403,
      headers: { 'Content-Type': 'application/json', ...corsHeaders },
    });
  }

  let items = [];
  let heartbeat = null;

  if (typeof SMS_KV !== 'undefined') {
    const idx = (await SMS_KV.get(`idx:${channelId}`, 'json')) || [];
    for (const id of idx) {
      const msg = await SMS_KV.get(`msg:${channelId}:${id}`, 'json');
      if (msg) {
        if (since && msg.timestamp <= since) continue;
        items.push(msg);
      }
    }
    heartbeat = await SMS_KV.get(`hb:${channelId}`, 'json');
  }

  return new Response(JSON.stringify({ success: true, items, heartbeat }), {
    headers: { 'Content-Type': 'application/json', ...corsHeaders },
  });
}

function handleStream(request, url) {
  const channelId = url.searchParams.get('channel');
  const token = url.searchParams.get('token');

  if (!channelId || !token) {
    return new Response('channel and token required', { status: 400 });
  }

  const { readable, writable } = new TransformStream();
  const writer = writable.getWriter();
  const encoder = new TextEncoder();

  // Send initial connected event
  writer.write(encoder.encode(`event: connected\ndata: {"channel":"${channelId}"}\n\n`));

  // Keep-alive ping interval
  const pingTimer = setInterval(() => {
    writer.write(encoder.encode(': ping\n\n')).catch(() => clearInterval(pingTimer));
  }, 25000);

  const client = {
    writer,
    encoder,
    close: () => {
      clearInterval(pingTimer);
      try { writer.close(); } catch (_) {}
    },
  };

  if (!sseClients.has(channelId)) {
    sseClients.set(channelId, new Set());
  }
  sseClients.get(channelId).add(client);

  request.signal.addEventListener('abort', () => {
    client.close();
    const set = sseClients.get(channelId);
    if (set) {
      set.delete(client);
      if (set.size === 0) sseClients.delete(channelId);
    }
  });

  return new Response(readable, {
    headers: {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache, no-transform',
      'Connection': 'keep-alive',
      'Access-Control-Allow-Origin': '*',
    },
  });
}

function broadcastSSE(channelId, payload) {
  const set = sseClients.get(channelId);
  if (!set || set.size === 0) return;
  const json = JSON.stringify(payload);
  const data = `data: ${json}\n\n`;
  for (const client of set) {
    try {
      client.writer.write(client.encoder.encode(data)).catch(() => {
        set.delete(client);
      });
    } catch (_) {
      set.delete(client);
    }
  }
}

// -----------------------------------------------------------------------------
// Web Dashboard HTML & Client-Side E2EE Decryptor
// -----------------------------------------------------------------------------

function renderDashboardHtml() {
  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <title>eUICC-Nexus 实时接码看板</title>
  <link rel="icon" href="data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 100 100%22><text y=%22.9em%22 font-size=%2290%22>⚡</text></svg>">
  <style>
    :root {
      --bg: #0b0d13;
      --card-bg: rgba(22, 27, 38, 0.85);
      --card-border: rgba(56, 189, 248, 0.15);
      --card-hover: rgba(56, 189, 248, 0.25);
      --text-main: #f1f5f9;
      --text-muted: #94a3b8;
      --accent: #38bdf8;
      --accent-glow: rgba(56, 189, 248, 0.35);
      --emerald: #10b981;
      --emerald-glow: rgba(16, 185, 129, 0.3);
      --amber: #f59e0b;
      --rose: #f43f5e;
      --font-mono: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
      --font-sans: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      background-color: var(--bg);
      background-image: 
        radial-gradient(circle at 15% 15%, rgba(56, 189, 248, 0.08) 0%, transparent 40%),
        radial-gradient(circle at 85% 85%, rgba(16, 185, 129, 0.06) 0%, transparent 40%);
      color: var(--text-main);
      font-family: var(--font-sans);
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      align-items: center;
      padding: 20px 16px 40px;
    }
    .container { width: 100%; max-width: 680px; }
    
    /* Top Bar */
    .header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 16px 20px;
      background: var(--card-bg);
      backdrop-filter: blur(12px);
      border: 1px solid var(--card-border);
      border-radius: 16px;
      margin-bottom: 20px;
      box-shadow: 0 4px 24px rgba(0,0,0,0.4);
    }
    .brand { display: flex; align-items: center; gap: 10px; font-weight: 700; font-size: 1.15rem; letter-spacing: -0.02em; }
    .brand-icon {
      width: 34px; height: 34px; border-radius: 10px;
      background: linear-gradient(135deg, var(--accent), var(--emerald));
      display: flex; align-items: center; justify-content: center;
      color: #000; font-weight: 900; font-size: 1.2rem;
    }
    .status-badge {
      display: flex; align-items: center; gap: 6px; font-size: 0.82rem; font-weight: 600;
      padding: 4px 10px; border-radius: 999px; background: rgba(16, 185, 129, 0.12);
      border: 1px solid rgba(16, 185, 129, 0.3); color: var(--emerald);
    }
    .status-badge.offline {
      background: rgba(244, 63, 94, 0.12); border-color: rgba(244, 63, 94, 0.3); color: var(--rose);
    }
    .status-dot { width: 8px; height: 8px; border-radius: 50%; background: currentColor; box-shadow: 0 0 8px currentColor; }
    
    /* Meta strip */
    .meta-bar {
      display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 10px;
      margin-bottom: 20px; padding: 0 4px; font-size: 0.82rem; color: var(--text-muted);
    }
    .chip {
      background: rgba(255,255,255,0.04); border: 1px solid rgba(255,255,255,0.08);
      padding: 4px 10px; border-radius: 8px; display: inline-flex; align-items: center; gap: 6px;
      cursor: pointer; transition: all 0.2s;
    }
    .chip:hover { border-color: var(--accent); color: var(--text-main); }
    .controls { display: flex; gap: 8px; }
    .btn-ctrl {
      background: transparent; border: 1px solid rgba(255,255,255,0.12);
      color: var(--text-muted); padding: 5px 10px; border-radius: 8px;
      cursor: pointer; font-size: 0.8rem; display: flex; align-items: center; gap: 4px;
      transition: all 0.2s;
    }
    .btn-ctrl:hover, .btn-ctrl.active { border-color: var(--accent); color: var(--accent); }

    /* Security banner */
    .sec-banner {
      background: rgba(16, 185, 129, 0.08); border: 1px solid rgba(16, 185, 129, 0.25);
      border-radius: 12px; padding: 10px 14px; margin-bottom: 20px; font-size: 0.82rem;
      display: flex; align-items: center; justify-content: space-between; gap: 8px; color: #a7f3d0;
    }
    .sec-banner.warn {
      background: rgba(245, 158, 11, 0.08); border-color: rgba(245, 158, 11, 0.3); color: #fde68a;
    }
    .btn-link { background: none; border: none; color: inherit; font-weight: 700; text-decoration: underline; cursor: pointer; }

    /* SMS Card */
    .sms-list { display: flex; flex-direction: column; gap: 16px; }
    .card {
      background: var(--card-bg);
      border: 1px solid var(--card-border);
      border-radius: 16px;
      padding: 20px;
      backdrop-filter: blur(12px);
      box-shadow: 0 4px 20px rgba(0,0,0,0.3);
      position: relative;
      transition: transform 0.2s, border-color 0.2s;
      animation: fadeIn 0.3s ease-out;
    }
    .card:hover { border-color: var(--card-hover); }
    @keyframes fadeIn {
      from { opacity: 0; transform: translateY(-8px); }
      to { opacity: 1; transform: translateY(0); }
    }
    .card-head {
      display: flex; justify-content: space-between; align-items: baseline; margin-bottom: 12px;
    }
    .sender-group { display: flex; align-items: center; gap: 8px; }
    .sender { font-size: 1.05rem; font-weight: 700; color: #fff; }
    .slot-tag {
      font-size: 0.72rem; padding: 2px 6px; border-radius: 4px;
      background: rgba(56, 189, 248, 0.15); color: var(--accent); border: 1px solid rgba(56, 189, 248, 0.3);
    }
    .time { font-size: 0.78rem; color: var(--text-muted); }

    /* Big OTP Highlight Box */
    .otp-box {
      background: rgba(15, 23, 42, 0.75);
      border: 1px dashed rgba(56, 189, 248, 0.4);
      border-radius: 12px;
      padding: 14px 18px;
      margin-bottom: 14px;
      display: flex;
      justify-content: space-between;
      align-items: center;
      gap: 12px;
    }
    .otp-code {
      font-family: var(--font-mono);
      font-size: 1.85rem;
      font-weight: 800;
      letter-spacing: 0.18em;
      color: #38bdf8;
      text-shadow: 0 0 16px var(--accent-glow);
    }
    .btn-copy {
      background: linear-gradient(135deg, #0284c7, #0ea5e9);
      color: #fff;
      border: none;
      padding: 8px 16px;
      border-radius: 8px;
      font-weight: 700;
      font-size: 0.88rem;
      cursor: pointer;
      display: flex;
      align-items: center;
      gap: 6px;
      box-shadow: 0 2px 10px rgba(14, 165, 233, 0.3);
      transition: all 0.2s;
    }
    .btn-copy:hover { transform: translateY(-1px); box-shadow: 0 4px 14px rgba(14, 165, 233, 0.5); }
    .btn-copy.copied {
      background: linear-gradient(135deg, #059669, #10b981);
      box-shadow: 0 2px 10px rgba(16, 185, 129, 0.4);
    }

    .sms-body {
      color: #cbd5e1;
      font-size: 0.92rem;
      line-height: 1.55;
      word-break: break-word;
      background: rgba(0,0,0,0.18);
      padding: 10px 12px;
      border-radius: 8px;
      border-left: 3px solid rgba(56, 189, 248, 0.4);
    }
    .highlight-otp {
      background: rgba(56, 189, 248, 0.25);
      color: #38bdf8;
      font-weight: 700;
      padding: 1px 4px;
      border-radius: 4px;
    }

    /* Empty state */
    .empty-state {
      text-align: center;
      padding: 60px 20px;
      color: var(--text-muted);
    }
    .pulse-ring {
      width: 56px; height: 56px; border-radius: 50%;
      border: 2px solid var(--accent); margin: 0 auto 16px;
      animation: pulse 2s infinite cubic-bezier(0.4, 0, 0.6, 1);
      display: flex; align-items: center; justify-content: center;
      color: var(--accent); font-size: 1.5rem;
    }
    @keyframes pulse {
      0%, 100% { transform: scale(1); opacity: 0.6; }
      50% { transform: scale(1.15); opacity: 1; }
    }

    /* Modal */
    .modal-backdrop {
      position: fixed; inset: 0; background: rgba(0,0,0,0.7);
      backdrop-filter: blur(6px); display: none; align-items: center; justify-content: center;
      padding: 16px; z-index: 100;
    }
    .modal-backdrop.show { display: flex; }
    .modal {
      background: #181d28; border: 1px solid var(--card-border); border-radius: 18px;
      max-width: 480px; width: 100%; padding: 24px; box-shadow: 0 10px 40px rgba(0,0,0,0.6);
    }
    .modal h3 { margin-bottom: 12px; font-size: 1.15rem; color: #fff; }
    .modal p { font-size: 0.88rem; color: var(--text-muted); line-height: 1.5; margin-bottom: 16px; }
    .input-group { margin-bottom: 16px; }
    .input-group label { display: block; font-size: 0.8rem; color: var(--text-muted); margin-bottom: 6px; font-weight: 600; }
    .input-control {
      width: 100%; padding: 10px 12px; background: #0c0e14; border: 1px solid rgba(255,255,255,0.15);
      border-radius: 8px; color: #fff; font-family: var(--font-mono); font-size: 0.88rem;
    }
    .input-control:focus { outline: none; border-color: var(--accent); }
    .modal-actions { display: flex; justify-content: flex-end; gap: 10px; }
    .btn-secondary { background: rgba(255,255,255,0.08); color: #cbd5e1; border: none; padding: 8px 14px; border-radius: 8px; cursor: pointer; }
    .btn-primary { background: var(--accent); color: #000; font-weight: 700; border: none; padding: 8px 18px; border-radius: 8px; cursor: pointer; }

    /* Toast */
    .toast {
      position: fixed; bottom: 24px; left: 50%; transform: translateX(-50%) translateY(100px);
      background: #10b981; color: #000; font-weight: 700; padding: 10px 20px; border-radius: 999px;
      box-shadow: 0 4px 20px var(--emerald-glow); opacity: 0; transition: all 0.3s cubic-bezier(0.18, 0.89, 0.32, 1.28);
      z-index: 999;
    }
    .toast.show { transform: translateX(-50%) translateY(0); opacity: 1; }
  </style>
</head>
<body>
  <div class="container">
    <!-- Header -->
    <header class="header">
      <div class="brand">
        <div class="brand-icon">⚡</div>
        <span>eUICC-Nexus</span>
      </div>
      <div id="deviceStatus" class="status-badge offline">
        <span class="status-dot"></span>
        <span id="deviceStatusText">备用机离线</span>
      </div>
    </header>

    <!-- Meta / Controls Bar -->
    <div class="meta-bar">
      <div class="chip" id="channelChip" title="点击复制完整接码链接">
        <span>🔗 通道:</span>
        <strong id="channelName">未配置</strong>
      </div>
      <div class="controls">
        <button id="btnSound" class="btn-ctrl active" title="提示音">🔊 声音</button>
        <button id="btnNotify" class="btn-ctrl" title="桌面通知">🔔 桌面提醒</button>
        <button id="btnKey" class="btn-ctrl" title="配置解密密钥">🔑 密钥</button>
      </div>
    </div>

    <!-- Security Banner -->
    <div id="secBanner" class="sec-banner">
      <div style="display:flex;align-items:center;gap:6px;">
        <span>🔒</span>
        <span id="secBannerText">端到端零知识解密已激活 (AES-256-GCM)</span>
      </div>
      <button class="btn-link" id="btnChangeKey">更换</button>
    </div>

    <!-- Live SMS Cards -->
    <main class="sms-list" id="smsContainer">
      <div class="empty-state" id="emptyState">
        <div class="pulse-ring">📡</div>
        <p><strong>等待备用机接码中...</strong></p>
        <p style="font-size:0.82rem;margin-top:6px;">当实体 eUICC 卡槽收到新短信时，将通过加密隧道秒级推送到此处</p>
      </div>
    </main>
  </div>

  <!-- Key Setup Modal -->
  <div class="modal-backdrop" id="keyModal">
    <div class="modal">
      <h3>🔑 配置隧道解密密钥</h3>
      <p>
        根据零知识架构，CF Worker 云端只存储不可读的密文。请从 App 中复制并输入本通道的解密密钥（支持 64 位 Hex 或 Base64）：
      </p>
      <div class="input-group">
        <label for="inputKey">Channel Secret (AES-256 密钥)</label>
        <input type="password" id="inputKey" class="input-control" placeholder="如: 7f8a9b... 或 Base64" autocomplete="off">
      </div>
      <p style="font-size:0.75rem;color:#64748b;">
        * 该密钥仅保留在您当前浏览器的内存/Hash中，绝对不会发送到 Cloudflare 服务器。
      </p>
      <div class="modal-actions">
        <button class="btn-secondary" id="btnCancelModal">取消</button>
        <button class="btn-primary" id="btnSaveKey">保存并解密</button>
      </div>
    </div>
  </div>

  <div class="toast" id="toast">已复制到剪贴板</div>

  <script>
    // -------------------------------------------------------------------------
    // Client-side E2EE Core & Live SSE / Polling Stream
    // -------------------------------------------------------------------------
    const state = {
      channel: '',
      keyRaw: '',
      cryptoKey: null,
      tokenHex: '',
      soundEnabled: true,
      notifyEnabled: false,
      seenIds: new Set(),
      items: [],
      deviceOnline: false,
      lastHeartbeatTime: 0,
    };

    // DOM Elements
    const dom = {
      channelName: document.getElementById('channelName'),
      channelChip: document.getElementById('channelChip'),
      deviceStatus: document.getElementById('deviceStatus'),
      deviceStatusText: document.getElementById('deviceStatusText'),
      secBanner: document.getElementById('secBanner'),
      secBannerText: document.getElementById('secBannerText'),
      smsContainer: document.getElementById('smsContainer'),
      emptyState: document.getElementById('emptyState'),
      btnSound: document.getElementById('btnSound'),
      btnNotify: document.getElementById('btnNotify'),
      btnKey: document.getElementById('btnKey'),
      btnChangeKey: document.getElementById('btnChangeKey'),
      keyModal: document.getElementById('keyModal'),
      inputKey: document.getElementById('inputKey'),
      btnCancelModal: document.getElementById('btnCancelModal'),
      btnSaveKey: document.getElementById('btnSaveKey'),
      toast: document.getElementById('toast'),
    };

    // Synthesized Audio chime
    function playChime() {
      if (!state.soundEnabled) return;
      try {
        const ctx = new (window.AudioContext || window.webkitAudioContext)();
        const osc = ctx.createOscillator();
        const gain = ctx.createGain();
        osc.type = 'sine';
        osc.frequency.setValueAtTime(587.33, ctx.currentTime); // D5
        osc.frequency.exponentialRampToValueAtTime(880, ctx.currentTime + 0.12); // A5
        gain.gain.setValueAtTime(0.2, ctx.currentTime);
        gain.gain.exponentialRampToValueAtTime(0.001, ctx.currentTime + 0.4);
        osc.connect(gain);
        gain.connect(ctx.destination);
        osc.start();
        osc.stop(ctx.currentTime + 0.45);
      } catch (_) {}
    }

    function showToast(text) {
      dom.toast.textContent = text;
      dom.toast.classList.add('show');
      setTimeout(() => dom.toast.classList.remove('show'), 2000);
    }

    // WebCrypto Helpers
    async function sha256Hex(buffer) {
      const digest = await crypto.subtle.digest('SHA-256', buffer);
      return Array.from(new Uint8Array(digest)).map(b => b.toString(16).padStart(2, '0')).join('');
    }

    function parseKeyBytes(str) {
      const clean = str.trim();
      // Hex (64 chars)
      if (/^[a-fA-F0-9]{64}$/.test(clean)) {
        const arr = new Uint8Array(32);
        for (let i = 0; i < 32; i++) arr[i] = parseInt(clean.substr(i * 2, 2), 16);
        return arr;
      }
      // Base64
      try {
        const bin = atob(clean);
        if (bin.length === 32) {
          const arr = new Uint8Array(32);
          for (let i = 0; i < 32; i++) arr[i] = bin.charCodeAt(i);
          return arr;
        }
      } catch (_) {}
      return null;
    }

    function base64ToUint8(b64) {
      const bin = atob(b64);
      const arr = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
      return arr;
    }

    async function initCryptoKey(keyBytes) {
      return await crypto.subtle.importKey(
        'raw',
        keyBytes,
        { name: 'AES-GCM' },
        false,
        ['decrypt']
      );
    }

    async function decryptPayload(ivBase64, ciphertextBase64) {
      if (!state.cryptoKey) throw new Error('no_key');
      const iv = base64ToUint8(ivBase64);
      const data = base64ToUint8(ciphertextBase64);
      const decrypted = await crypto.subtle.decrypt(
        { name: 'AES-GCM', iv },
        state.cryptoKey,
        data
      );
      const text = new TextDecoder('utf-8').decode(decrypted);
      return JSON.parse(text);
    }

    // Regular Expression for 4-8 digit OTP
    function extractOtp(body) {
      if (!body) return null;
      // Keywords check
      const kw = /(?:验证码|校验码|动态码|code|otp|verification|pin)\b[^0-9]{0,12}([0-9]{4,8})\b/i.exec(body);
      if (kw && kw[1]) return kw[1];
      // Standalone numbers
      const stand = /(?<![0-9+-])([0-9]{4,8})(?![0-9])/g;
      let match;
      while ((match = stand.exec(body)) !== null) {
        if (!/(?:19[0-9]{2}|20[0-2][0-9])/.test(match[1])) {
          return match[1];
        }
      }
      return null;
    }

    function formatTime(epoch) {
      if (!epoch) return '';
      const diff = Math.floor((Date.now() - epoch) / 1000);
      if (diff < 15) return '刚刚';
      if (diff < 60) return diff + '秒前';
      if (diff < 3600) return Math.floor(diff / 60) + '分钟前';
      const d = new Date(epoch);
      return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    }

    function escapeHtml(str) {
      return String(str || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
    }

    function renderCard(msg) {
      const otp = msg.otp || extractOtp(msg.body);
      let bodyHtml = escapeHtml(msg.body);
      if (otp) {
        bodyHtml = bodyHtml.replace(otp, '<span class="highlight-otp">' + escapeHtml(otp) + '</span>');
      }

      const card = document.createElement('div');
      card.className = 'card';
      card.id = 'card_' + msg.id;

      let otpHtml = '';
      if (otp) {
        otpHtml = \`
          <div class="otp-box">
            <span class="otp-code">\${escapeHtml(otp.split('').join(' '))}</span>
            <button class="btn-copy" onclick="copyOtp('\${escapeHtml(otp)}', this)">
              <span>📋</span> 复制
            </button>
          </div>
        \`;
      }

      const slotStr = msg.slot ? \`SIM \${msg.slot}\` : '';
      const carrierStr = msg.carrier ? \` · \${msg.carrier}\` : '';
      const slotTag = (slotStr || carrierStr) ? \`<span class="slot-tag">\${escapeHtml(slotStr + carrierStr)}</span>\` : '';

      card.innerHTML = \`
        <div class="card-head">
          <div class="sender-group">
            <span class="sender">\${escapeHtml(msg.sender || '未知号码')}</span>
            \${slotTag}
          </div>
          <span class="time" title="\${new Date(msg.timestamp).toLocaleString()}">\${formatTime(msg.timestamp)}</span>
        </div>
        \${otpHtml}
        <div class="sms-body">\${bodyHtml}</div>
      \`;

      return card;
    }

    window.copyOtp = function(code, btn) {
      navigator.clipboard.writeText(code).then(() => {
        btn.innerHTML = '<span>✓</span> 已复制';
        btn.classList.add('copied');
        showToast('验证码 ' + code + ' 已复制');
        setTimeout(() => {
          btn.innerHTML = '<span>📋</span> 复制';
          btn.classList.remove('copied');
        }, 2000);
      });
    };

    function updateDeviceStatus(online, meta) {
      state.deviceOnline = online;
      if (online) {
        dom.deviceStatus.className = 'status-badge';
        let detail = '备用机在线';
        if (meta && meta.battery) detail += \` · \${meta.battery}%\`;
        if (meta && meta.carrier) detail += \` · \${meta.carrier}\`;
        dom.deviceStatusText.textContent = detail;
      } else {
        dom.deviceStatus.className = 'status-badge offline';
        dom.deviceStatusText.textContent = '备用机离线';
      }
    }

    // Ingest & Process Encrypted Item
    async function processEncryptedItem(item, isNewArrival = false) {
      if (!item || !item.id || state.seenIds.has(item.id)) return;
      state.seenIds.add(item.id);

      try {
        const decrypted = await decryptPayload(item.iv, item.ciphertext);
        decrypted.id = item.id;
        decrypted.timestamp = item.timestamp || decrypted.timestamp;
        
        dom.emptyState.style.display = 'none';
        const card = renderCard(decrypted);
        dom.smsContainer.insertBefore(card, dom.smsContainer.firstChild);

        if (isNewArrival) {
          playChime();
          const otp = decrypted.otp || extractOtp(decrypted.body);
          if (state.notifyEnabled && Notification.permission === 'granted') {
            new Notification('⚡ 新验证码: ' + (otp || decrypted.sender), {
              body: decrypted.body,
              icon: 'data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 100 100%22><text y=%22.9em%22 font-size=%2290%22>⚡</text></svg>'
            });
          }
        }
      } catch (e) {
        console.warn('Decryption failed for item', item.id, e);
      }
    }

    // Stream & Polling Pipeline
    let sseSource = null;
    function connectSSE() {
      if (!state.channel || !state.tokenHex) return;
      if (sseSource) sseSource.close();

      const streamUrl = \`/api/stream?channel=\${encodeURIComponent(state.channel)}&token=\${encodeURIComponent(state.tokenHex)}\`;
      sseSource = new EventSource(streamUrl);

      sseSource.onmessage = async (e) => {
        try {
          const data = JSON.parse(e.data);
          if (data.type === 'sms' && data.item) {
            await processEncryptedItem(data.item, true);
          } else if (data.type === 'heartbeat' && data.data) {
            try {
              const hb = await decryptPayload(data.data.iv, data.data.ciphertext);
              updateDeviceStatus(true, hb);
            } catch (_) {
              updateDeviceStatus(true, null);
            }
          }
        } catch (_) {}
      };

      sseSource.onerror = () => {
        // SSE disconnected, fallback loop keeps syncing
      };
    }

    async function pollRecent() {
      if (!state.channel || !state.tokenHex) return;
      try {
        const resp = await fetch(\`/api/poll?channel=\${encodeURIComponent(state.channel)}&token=\${encodeURIComponent(state.tokenHex)}\`);
        if (!resp.ok) return;
        const res = await resp.json();
        if (res.items && Array.isArray(res.items)) {
          // Process in chronological order (oldest first so newest ends on top)
          const sorted = [...res.items].sort((a,b) => a.timestamp - b.timestamp);
          for (const item of sorted) {
            await processEncryptedItem(item, false);
          }
        }
        if (res.heartbeat) {
          try {
            const hb = await decryptPayload(res.heartbeat.iv, res.heartbeat.ciphertext);
            const isFresh = (Date.now() - (res.heartbeat.timestamp || 0)) < 90000;
            updateDeviceStatus(isFresh, hb);
          } catch (_) {
            updateDeviceStatus(true, null);
          }
        }
      } catch (_) {}
    }

    // Boot & URL Parser
    async function boot() {
      const url = new URL(window.location.href);
      state.channel = url.searchParams.get('channel') || '';
      
      // Hash key extraction: #key=... or #...
      let hash = window.location.hash.substring(1).trim();
      if (hash.startsWith('key=')) hash = hash.substring(4);
      state.keyRaw = hash;

      if (!state.channel) {
        state.channel = 'ch_default';
      }
      dom.channelName.textContent = state.channel;

      dom.channelChip.onclick = () => {
        navigator.clipboard.writeText(window.location.href).then(() => showToast('已复制完整接码链接'));
      };

      const keyBytes = parseKeyBytes(state.keyRaw);
      if (keyBytes) {
        state.cryptoKey = await initCryptoKey(keyBytes);
        state.tokenHex = await sha256Hex(keyBytes);
        dom.secBanner.className = 'sec-banner';
        dom.secBannerText.textContent = '端到端零知识解密已激活 (AES-256-GCM)';
        connectSSE();
        await pollRecent();
        // Polling loop as backup
        setInterval(pollRecent, 5000);
      } else {
        dom.secBanner.className = 'sec-banner warn';
        dom.secBannerText.textContent = '尚未配置解密密钥，无法解密收到的验证码';
        dom.keyModal.classList.add('show');
      }

      // Event listeners
      dom.btnKey.onclick = dom.btnChangeKey.onclick = () => {
        dom.inputKey.value = state.keyRaw;
        dom.keyModal.classList.add('show');
      };
      dom.btnCancelModal.onclick = () => dom.keyModal.classList.remove('show');
      dom.btnSaveKey.onclick = async () => {
        const val = dom.inputKey.value.trim();
        const b = parseKeyBytes(val);
        if (!b) {
          alert('密钥格式不正确！请输入 64 位 Hex 字符串或 32 字节 Base64。');
          return;
        }
        window.location.hash = 'key=' + val;
        window.location.reload();
      };

      dom.btnSound.onclick = () => {
        state.soundEnabled = !state.soundEnabled;
        dom.btnSound.classList.toggle('active', state.soundEnabled);
        dom.btnSound.textContent = state.soundEnabled ? '🔊 声音' : '🔇 静音';
      };

      dom.btnNotify.onclick = async () => {
        if (!('Notification' in window)) return alert('当前浏览器不支持桌面通知');
        const perm = await Notification.requestPermission();
        if (perm === 'granted') {
          state.notifyEnabled = true;
          dom.btnNotify.classList.add('active');
          showToast('桌面提醒已开启');
        } else {
          state.notifyEnabled = false;
          dom.btnNotify.classList.remove('active');
        }
      };
    }

    window.addEventListener('DOMContentLoaded', boot);
  </script>
</body>
</html>`;
}
