/**
 * WebSocket signaling — used with native phone app + deployed server.
 */
(function () {
  function wsUrl() {
    const cfg = window.CASTER_CONFIG || {};
    if (cfg.SIGNALING_URL) return cfg.SIGNALING_URL;
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    if (cfg.SIGNALING_HOST) return `${proto}//${cfg.SIGNALING_HOST}`;
    return null;
  }

  function connect() {
    const url = wsUrl();
    if (!url) return Promise.reject(new Error('Signaling server URL not configured.'));
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(url);
      const timer = setTimeout(() => {
        ws.close();
        reject(new Error('Signaling server timeout. Is the server running?'));
      }, 15000);
      ws.onopen = () => { clearTimeout(timer); resolve(ws); };
      ws.onerror = () => { clearTimeout(timer); reject(new Error('Could not reach signaling server.')); };
    });
  }

  function waitFor(ws, types, ms = 20000) {
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

  window.CasterWS = { connect, send, waitFor, pairDesktop, joinGlasses, wsUrl };
})();
