/**
 * Glasses UI — digit pad for Meta Display (Enter only, no click)
 */
(function () {
  const useWS = !!(window.CASTER_CONFIG?.SIGNALING_URL || window.CASTER_CONFIG?.SIGNALING_HOST);
  const params = new URLSearchParams(location.search);
  const presetCode = params.get('code')?.replace(/\D/g, '').slice(0, 6);

  const els = {
    pairingView: document.getElementById('pairing-view'),
    connectedView: document.getElementById('connected-view'),
    status: document.getElementById('status'),
    statusText: document.getElementById('status-text'),
    connectedLabel: document.getElementById('connected-label'),
    streamHint: document.getElementById('stream-hint'),
    streamBtn: document.getElementById('stream-btn'),
    sessionCode: document.getElementById('session-code'),
    digitDisplay: document.getElementById('digit-display'),
    backspaceBtn: document.getElementById('backspace-btn'),
    joinBtn: document.getElementById('join-btn'),
    versionLabel: document.getElementById('version-label'),
  };

  const KEY_COOLDOWN_MS = 450;
  const START_RETRY_MS = 2000;
  const START_RETRY_MAX = 4;

  let ws = null;
  let dataConn = null;
  let peer = null;
  let connected = false;
  let streaming = false;
  let digits = presetCode || '';
  let lastKeyAction = { key: '', at: 0 };
  let startRetryTimer = null;
  let startRetryCount = 0;

  if (els.versionLabel) {
    els.versionLabel.textContent = useWS ? 'ws-v29' : `v${CasterSignaling.APP_VERSION}`;
  }

  function setStatus(kind, text) {
    els.status.className = `status ${kind}`;
    els.statusText.textContent = text;
  }

  function renderDigits() {
    const padded = (digits + '------').slice(0, 6);
    if (els.digitDisplay) els.digitDisplay.textContent = padded;
  }

  function isDuplicateKey(key) {
    const now = Date.now();
    if (lastKeyAction.key === key && now - lastKeyAction.at < KEY_COOLDOWN_MS) return true;
    lastKeyAction = { key, at: now };
    return false;
  }

  function pressDigit(d) {
    if (isDuplicateKey(`digit-${d}`)) return;
    if (digits.length < 6) digits += d;
    renderDigits();
  }

  function backspace() {
    if (isDuplicateKey('backspace')) return;
    digits = digits.slice(0, -1);
    renderDigits();
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
    els.pairingView.classList.add('hidden');
    els.connectedView.classList.remove('hidden');
    els.connectedLabel.textContent = 'Ready';
    if (els.sessionCode) els.sessionCode.textContent = digits;
    els.streamHint.textContent = 'Live Stream turns on glasses camera via phone app.';
    setStatus('connected', 'Ready');
    els.streamBtn.focus();
  }

  function clearStartRetry() {
    if (startRetryTimer) {
      window.clearInterval(startRetryTimer);
      startRetryTimer = null;
    }
    startRetryCount = 0;
  }

  function sendStartStream() {
    if (useWS) CasterWS.send(ws, { type: 'start-stream' });
    else CasterSignaling.sendData(dataConn, { type: 'start-stream' });
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
    const onMsg = (msg) => {
      if (msg?.type === 'stream-starting') {
        els.streamHint.textContent = 'Phone is turning on glasses camera…';
        setStatus('waiting', 'Starting camera…');
      }
      if (msg?.type === 'stream-started') {
        clearStartRetry();
        streaming = true;
        els.streamBtn.textContent = 'Stop Stream';
        els.streamBtn.classList.add('active');
        els.streamHint.textContent = 'Casting live POV to desktop…';
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
    };

    if (useWS && ws) {
      ws.addEventListener('message', (ev) => {
        try { onMsg(JSON.parse(ev.data)); } catch { /* ignore */ }
      });
      ws.addEventListener('close', () => {
        clearStartRetry();
        connected = false;
        setStatus('error', 'Disconnected');
        els.joinBtn.disabled = false;
      });
    } else if (dataConn) {
      dataConn.on('data', onMsg);
      dataConn.on('close', () => {
        clearStartRetry();
        connected = false;
        setStatus('error', 'Disconnected');
        els.joinBtn.disabled = false;
      });
    }
  }

  async function joinSession() {
    const code = digits.replace(/\D/g, '').slice(0, 6);
    if (code.length !== 6) return;

    els.joinBtn.disabled = true;
    setStatus('waiting', 'Connecting…');

    try {
      if (useWS) {
        ws = await CasterWS.joinGlasses(code);
      } else {
        peer?.destroy();
        peer = await CasterSignaling.createPeerWithRetry();
        dataConn = await CasterSignaling.connectToRelay(code, peer, 'glasses', (msg) => setStatus('waiting', msg));
      }
      bindStreamMessages();
      showConnected();
    } catch (err) {
      console.error(err);
      setStatus('error', err.message || 'Could not connect.');
      els.joinBtn.disabled = false;
    }
  }

  function toggleStream() {
    if (!connected) return;
    if (isDuplicateKey('stream')) return;

    if (streaming) {
      clearStartRetry();
      if (useWS) CasterWS.send(ws, { type: 'stop-stream' });
      else CasterSignaling.sendData(dataConn, { type: 'stop-stream' });
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

  document.querySelectorAll('.digit-btn[data-digit]').forEach((btn) => {
    bindEnterOnly(btn, () => pressDigit(btn.dataset.digit));
  });

  bindEnterOnly(els.backspaceBtn, backspace);
  bindEnterOnly(els.joinBtn, joinSession);
  bindEnterOnly(els.streamBtn, toggleStream);

  renderDigits();

  if (presetCode.length === 6) joinSession();
  else setStatus('waiting', useWS ? 'Enter code from phone app' : 'Enter code from phone relay');
})();
