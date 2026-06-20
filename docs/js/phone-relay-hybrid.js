/**
 * Phone relay — WebSocket signaling (required for iPhone profile app).
 */
(function () {
  const els = {
    pairCode: document.getElementById('pair-code'),
    codeTimer: document.getElementById('code-timer'),
    status: document.getElementById('status'),
    statusText: document.getElementById('status-text'),
    connectedView: document.getElementById('connected-view'),
    pairingView: document.getElementById('pairing-view'),
    connectedLabel: document.getElementById('connected-label'),
    sessionCode: document.getElementById('session-code'),
    streamHint: document.getElementById('stream-hint'),
    keepOpenHint: document.getElementById('keep-open-hint'),
    desktopLink: document.getElementById('desktop-link'),
    networkDot: document.getElementById('network-dot'),
    relayHint: document.getElementById('relay-hint'),
  };

  const ROTATION_MS = window.CASTER_CONFIG?.CODE_ROTATION_MS || 300_000;

  let ws = null;
  let currentCode = '';
  let codeExpiresAt = 0;
  let timerInterval = null;
  let starting = false;
  let wakeLock = null;

  function setStatus(kind, text) {
    if (!els.status) return;
    els.status.className = `status ${kind}`;
    if (els.statusText) els.statusText.textContent = text;
  }

  function setNetworkOnline(online) {
    if (els.networkDot) els.networkDot.className = online ? 'network-dot online' : 'network-dot offline';
  }

  async function requestWakeLock() {
    try {
      if ('wakeLock' in navigator) {
        wakeLock?.release?.();
        wakeLock = await navigator.wakeLock.request('screen');
      }
    } catch { /* optional */ }
  }

  function updateTimer() {
    const left = Math.max(0, Math.ceil((codeExpiresAt - Date.now()) / 1000));
    if (!els.codeTimer) return;
    if (left > 0) els.codeTimer.textContent = `Code expires in ${left}s`;
    else els.codeTimer.textContent = 'Updating code…';
  }

  function showCode(code) {
    currentCode = code;
    if (els.pairCode) els.pairCode.textContent = code;
    if (els.desktopLink) els.desktopLink.href = `./?code=${code}`;
    if (els.relayHint) els.relayHint.textContent = `Session ${code}`;
    codeExpiresAt = Date.now() + ROTATION_MS;
    updateTimer();
  }

  function showSessionView(desktop, glasses) {
    if (!desktop && !glasses) {
      els.connectedView?.classList.add('hidden');
      els.pairingView?.classList.remove('hidden');
      setStatus('waiting', 'Ready — enter this code on desktop & glasses');
      return;
    }
    els.pairingView?.classList.add('hidden');
    els.connectedView?.classList.remove('hidden');
    if (els.sessionCode) els.sessionCode.textContent = currentCode;
    if (els.connectedLabel) {
      els.connectedLabel.textContent = desktop && glasses ? 'All connected' : 'Partially connected';
    }
    if (els.streamHint) {
      els.streamHint.textContent = desktop && glasses
        ? 'Tap Live Stream on glasses to cast.'
        : 'Waiting for all devices…';
    }
  }

  function bindMessages() {
    ws.addEventListener('message', async (ev) => {
      let msg;
      try { msg = JSON.parse(ev.data); } catch { return; }

      if (msg.type === 'relay-registered' || msg.type === 'code-rotated') {
        showCode(msg.code);
        setNetworkOnline(true);
        setStatus('waiting', 'Ready — enter this code on desktop & glasses');
        showSessionView(false, false);
      }
      if (msg.type === 'desktop-joined') {
        setStatus('connected', 'Desktop connected');
        showSessionView(true, !!msg.glassesOnline);
      }
      if (msg.type === 'glasses-joined') {
        setStatus('connected', msg.desktopOnline ? 'Desktop & glasses linked' : 'Glasses connected');
        showSessionView(!!msg.desktopOnline, true);
      }
      if (msg.type === 'desktop-left') showSessionView(false, true);
      if (msg.type === 'glasses-left') showSessionView(true, false);
      if (msg.type === 'start-stream') {
        setStatus('waiting', 'Starting camera…');
        await CasterWebRTCPhone.startStream(ws);
        setStatus('connected', 'Streaming to desktop');
      }
      if (msg.type === 'stop-stream') {
        CasterWebRTCPhone.stopStream();
        setStatus('connected', 'Ready — tap Live Stream on glasses');
      }
      if (msg.type === 'answer') await CasterWebRTCPhone.handleAnswer(msg);
      if (msg.type === 'ice-candidate') await CasterWebRTCPhone.handleRemoteIce(msg);
    });

    ws.addEventListener('close', () => {
      setNetworkOnline(false);
      setStatus('error', 'Relay disconnected — tap Restart relay');
    });
  }

  async function startRelay() {
    if (starting || ws?.readyState === WebSocket.OPEN) return;
    if (!CasterWS.wsUrl()) {
      setNetworkOnline(false);
      setStatus('error', 'Server not configured — open deploy-server.html');
      return;
    }

    starting = true;
    if (els.pairCode) els.pairCode.textContent = '······';
    setStatus('waiting', 'Connecting to signaling server… (may take up to 60s on free tier)');
    setNetworkOnline(false);

    try {
      await requestWakeLock();
      ws = await CasterWS.connect();
      bindMessages();
      CasterWS.send(ws, { type: 'register-relay' });
    } catch (err) {
      setNetworkOnline(false);
      const base = CasterWS.httpBase();
      setStatus('error', err.message || 'Could not connect');
      if (els.relayHint && base) {
        els.relayHint.innerHTML = `Server may be asleep. <a href="deploy-server.html">Deploy / check server</a>`;
      }
    } finally {
      starting = false;
    }
  }

  function restartRelay() {
    CasterWebRTCPhone.stopStream();
    ws?.close();
    ws = null;
    startRelay();
  }

  window.CasterRelay = { start: startRelay, restart: restartRelay };

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') {
      requestWakeLock();
      if (!ws || ws.readyState !== WebSocket.OPEN) startRelay();
    }
  });

  if (!timerInterval) timerInterval = setInterval(updateTimer, 1000);
  if (els.keepOpenHint) {
    els.keepOpenHint.textContent = 'Keep this app open. Enter the code on desktop and glasses.';
  }
})();
