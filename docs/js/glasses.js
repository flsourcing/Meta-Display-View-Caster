/**
 * Glasses UI — auto-links to phone relay, Live Stream only (no code entry).
 */
(function () {
  const useWS = !!(window.CASTER_CONFIG?.SIGNALING_URL || window.CASTER_CONFIG?.SIGNALING_HOST);

  const els = {
    status: document.getElementById('status'),
    statusText: document.getElementById('status-text'),
    connectedLabel: document.getElementById('connected-label'),
    streamHint: document.getElementById('stream-hint'),
    streamBtn: document.getElementById('stream-btn'),
    versionLabel: document.getElementById('version-label'),
  };

  const KEY_COOLDOWN_MS = 450;
  const START_RETRY_MS = 2000;
  const START_RETRY_MAX = 4;
  const AUTO_RECONNECT_MS = 5000;

  let ws = null;
  let connected = false;
  let streaming = false;
  let lastKeyAction = { key: '', at: 0 };
  let startRetryTimer = null;
  let startRetryCount = 0;
  let reconnectTimer = null;

  if (els.versionLabel) {
    els.versionLabel.textContent = useWS ? 'auto-v40' : `v${CasterSignaling.APP_VERSION}`;
  }

  function setStatus(kind, text) {
    els.status.className = `status ${kind}`;
    els.statusText.textContent = text;
  }

  function isDuplicateKey(key) {
    const now = Date.now();
    if (lastKeyAction.key === key && now - lastKeyAction.at < KEY_COOLDOWN_MS) return true;
    lastKeyAction = { key, at: now };
    return false;
  }

  function bindEnterOnly(el, fn) {
    if (!el) return;
    el.addEventListener('keydown', (e) => {
      if (e.key !== 'Enter') return;
      if (e.repeat) { e.preventDefault(); return; }
      e.preventDefault();
      e.stopImmediatePropagation();
      fn();
    });
    el.addEventListener('click', (e) => {
      e.preventDefault();
      e.stopImmediatePropagation();
    });
  }

  function showConnected() {
    connected = true;
    els.connectedLabel.textContent = 'Ready';
    els.streamHint.textContent = 'Live Stream turns on glasses camera via your phone.';
    setStatus('connected', 'Ready');
    els.streamBtn?.focus();
  }

  function clearStartRetry() {
    if (startRetryTimer) {
      window.clearInterval(startRetryTimer);
      startRetryTimer = null;
    }
    startRetryCount = 0;
  }

  function scheduleReconnect() {
    if (reconnectTimer) return;
    reconnectTimer = window.setTimeout(() => {
      reconnectTimer = null;
      if (!connected) connectToPhone();
    }, AUTO_RECONNECT_MS);
  }

  function sendStartStream() {
    if (useWS) CasterWS.send(ws, { type: 'start-stream' });
  }

  function wakePhoneApp() {
    const url = 'bypassmarketchecker://cast/start';
    try {
      const iframe = document.createElement('iframe');
      iframe.style.display = 'none';
      iframe.src = url;
      document.body.appendChild(iframe);
      window.setTimeout(() => iframe.remove(), 1200);
      const a = document.createElement('a');
      a.href = url;
      a.style.display = 'none';
      document.body.appendChild(a);
      a.click();
      a.remove();
    } catch (_) { /* ignore */ }
  }

  function bindStreamMessages() {
    if (!ws) return;
    ws.addEventListener('message', (ev) => {
      let msg;
      try { msg = JSON.parse(ev.data); } catch { return; }
      if (msg?.type === 'stream-starting') {
        els.streamHint.textContent = 'Phone is turning on glasses camera…';
        setStatus('waiting', 'Starting camera…');
      }
      if (msg?.type === 'stream-started') {
        clearStartRetry();
        streaming = true;
        els.streamBtn.textContent = 'Stop Stream';
        els.streamBtn.classList.add('active');
        els.streamHint.textContent = 'Casting live POV to viewers…';
        setStatus('connected', 'Casting');
      }
      if (msg?.type === 'stream-error') {
        clearStartRetry();
        streaming = false;
        els.streamBtn.textContent = 'Live Stream';
        els.streamBtn.classList.remove('active');
        const errText = msg.message || 'Stream failed — open View Caster on phone and tap Prepare Glasses.';
        els.streamHint.textContent = errText;
        setStatus('error', errText);
      }
      if (msg?.type === 'stop-stream') {
        clearStartRetry();
        streaming = false;
        els.streamBtn.textContent = 'Live Stream';
        els.streamBtn.classList.remove('active');
        els.streamHint.textContent = 'Press Enter on Live Stream to cast again.';
        setStatus('connected', 'Ready');
      }
      if (msg?.type === 'relay-offline') {
        connected = false;
        streaming = false;
        els.connectedLabel.textContent = 'Reconnecting…';
        els.streamHint.textContent = 'Phone relay offline — open View Caster on your phone.';
        setStatus('waiting', 'Phone offline');
        scheduleReconnect();
      }
    });
    ws.addEventListener('close', () => {
      clearStartRetry();
      connected = false;
      streaming = false;
      els.connectedLabel.textContent = 'Reconnecting…';
      setStatus('waiting', 'Reconnecting…');
      scheduleReconnect();
    });
  }

  async function connectToPhone() {
    if (!useWS) {
      setStatus('error', 'Signaling server not configured.');
      return;
    }

    setStatus('waiting', 'Connecting to phone…');
    els.streamHint.textContent = 'Linking to View Caster on your phone…';

    try {
      await CasterWS.wakeServer?.().catch(() => {});
      ws = await CasterWS.joinGlassesAuto();
      bindStreamMessages();
      showConnected();
    } catch (err) {
      console.error(err);
      connected = false;
      els.connectedLabel.textContent = 'Waiting for phone';
      els.streamHint.textContent = err.message || 'Open View Caster on your phone, then this page will connect automatically.';
      setStatus('waiting', 'Waiting for phone');
      scheduleReconnect();
    }
  }

  function toggleStream() {
    if (!connected) {
      connectToPhone();
      return;
    }
    if (isDuplicateKey('stream')) return;

    if (streaming) {
      clearStartRetry();
      CasterWS.send(ws, { type: 'stop-stream' });
      streaming = false;
      els.streamBtn.textContent = 'Live Stream';
      els.streamBtn.classList.remove('active');
      els.streamHint.textContent = 'Press Enter on Live Stream to cast again.';
    } else {
      clearStartRetry();
      els.streamHint.textContent = 'Turning on glasses camera…';
      setStatus('waiting', 'Starting camera…');
      wakePhoneApp();
      sendStartStream();
      startRetryCount = 1;
      startRetryTimer = window.setInterval(() => {
        if (streaming || startRetryCount >= START_RETRY_MAX) {
          clearStartRetry();
          if (!streaming) {
            els.streamHint.textContent = 'Phone not responding — open View Caster and tap Prepare Glasses.';
            setStatus('error', 'Phone not responding');
          }
          return;
        }
        startRetryCount += 1;
        sendStartStream();
      }, START_RETRY_MS);
    }
  }

  bindEnterOnly(els.streamBtn, toggleStream);
  connectToPhone();
})();
