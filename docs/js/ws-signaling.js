/**
 * WebSocket signaling — pairing goes through server (reliable iPhone ↔ desktop).
 */
(function () {
  function wsUrl() {
    const cfg = window.CASTER_CONFIG || {};
    if (cfg.SIGNALING_URL) return cfg.SIGNALING_URL;
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    if (cfg.SIGNALING_HOST) return `${proto}//${cfg.SIGNALING_HOST}`;
    return null;
  }

  function httpBase() {
    const url = wsUrl();
    if (!url) return null;
    return url.replace(/^wss:/i, 'https:').replace(/^ws:/i, 'http:').replace(/\/$/, '');
  }

  async function wakeServer() {
    const base = httpBase();
    if (!base) return false;
    try {
      const res = await fetch(`${base}/health`, { cache: 'no-store', mode: 'cors' });
      return res.ok;
    } catch {
      return false;
    }
  }

  function connectOnce(url, ms) {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(url);
      const timer = setTimeout(() => {
        ws.close();
        reject(new Error('Signaling server timeout. Free servers may take up to 60s to wake — try again.'));
      }, ms);
      ws.onopen = () => { clearTimeout(timer); resolve(ws); };
      ws.onerror = () => {
        clearTimeout(timer);
        reject(new Error('Could not reach signaling server.'));
      };
    });
  }

  async function connect() {
    const url = wsUrl();
    if (!url) {
      return Promise.reject(new Error('Signaling server not configured. Deploy the server first (see deploy-server.html).'));
    }
    await wakeServer();
    try {
      return await connectOnce(url, 20000);
    } catch (first) {
      await wakeServer();
      await sleep(3000);
      return connectOnce(url, 45000);
    }
  }

  function sleep(ms) {
    return new Promise((r) => setTimeout(r, ms));
  }

  function waitFor(ws, types, ms = 30000) {
    const want = Array.isArray(types) ? types : [types];
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        ws.removeEventListener('message', onMsg);
        reject(new Error('Signaling timeout.'));
      }, ms);
      function onMsg(ev) {
        let msg;
        try { msg = JSON.parse(ev.data); } catch { return; }
        if (msg.type === 'error') {
          clearTimeout(timer);
          ws.removeEventListener('message', onMsg);
          reject(new Error(msg.message || 'Signaling error.'));
          return;
        }
        if (want.includes(msg.type)) {
          clearTimeout(timer);
          ws.removeEventListener('message', onMsg);
          resolve(msg);
        }
      }
      ws.addEventListener('message', onMsg);
    });
  }

  function send(ws, payload) {
    if (ws?.readyState === WebSocket.OPEN) ws.send(JSON.stringify(payload));
  }

  async function pairDesktop(code) {
    const ws = await connect();
    send(ws, { type: 'pair', code });
    await waitFor(ws, 'relay-ack');
    return ws;
  }

  async function joinGlasses(code) {
    const ws = await connect();
    send(ws, { type: 'join-glasses', code });
    await waitFor(ws, 'relay-ack');
    return ws;
  }

  async function verifyViewerPassword(password) {
    const ws = await connect();
    send(ws, { type: 'verify-viewer-password', password });
    const msg = await waitFor(ws, 'viewer-password-ok');
    ws.close();
    return { relayOnline: !!msg.relayOnline, streaming: !!msg.streaming };
  }

  async function joinViewer(password, name) {
    const ws = await connect();
    send(ws, { type: 'join-viewer', password, name });
    const msg = await waitFor(ws, 'viewer-ack');
    return {
      ws,
      viewerId: msg.viewerId,
      streaming: !!msg.streaming,
      relayOnline: !!msg.relayOnline,
      viewers: msg.viewers || [],
      chatHistory: msg.chatHistory || [],
    };
  }

  async function fetchLiveStatus() {
    const base = httpBase();
    if (!base) return { relayOnline: false, streaming: false };
    try {
      const res = await fetch(`${base}/live-status`, { cache: 'no-store', mode: 'cors' });
      if (!res.ok) return { relayOnline: false, streaming: false };
      return res.json();
    } catch {
      return { relayOnline: false, streaming: false };
    }
  }

  window.CasterWS = { connect, send, waitFor, pairDesktop, joinGlasses, joinViewer, verifyViewerPassword, fetchLiveStatus, wsUrl, wakeServer, httpBase };
})();
