/**
 * Phone relay — hosts pairing session. Keep this page open in foreground.
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
    streamBtn: document.getElementById('stream-btn'),
    keepOpenHint: document.getElementById('keep-open-hint'),
    desktopLink: document.getElementById('desktop-link'),
  };

  const ROTATION_MS = window.CASTER_CONFIG?.CODE_ROTATION_MS || 300_000;

  let peer = null;
  let dataConn = null;
  let camConn = null;
  let connected = false;
  let streaming = false;
  let desktopPeerId = null;
  let currentCode = '';
  let codeExpiresAt = 0;
  let timerInterval = null;
  let rotationTimeout = null;
  let registering = false;
  let wakeLock = null;

  function setStatus(kind, text) {
    els.status.className = `status ${kind}`;
    els.statusText.textContent = text;
  }

  async function requestWakeLock() {
    try {
      if ('wakeLock' in navigator) {
        wakeLock = await navigator.wakeLock.request('screen');
      }
    } catch {
      /* optional */
    }
  }

  function updateTimer() {
    const left = Math.max(0, Math.ceil((codeExpiresAt - Date.now()) / 1000));
    els.codeTimer.textContent = connected
      ? 'Session active — keep this page open'
      : left > 0 ? `Code expires in ${left}s` : 'Updating code…';
  }

  function showCode(code) {
    currentCode = code;
    els.pairCode.textContent = code;
    codeExpiresAt = Date.now() + ROTATION_MS;
    updateTimer();
    if (!timerInterval) timerInterval = setInterval(updateTimer, 1000);

    const base = location.href.replace(/[^/]*$/, '');
    if (els.desktopLink) {
      els.desktopLink.href = `${base}?code=${code}`;
      els.desktopLink.textContent = 'Open desktop viewer with code';
    }
  }

  function captureUrl() {
    return `capture.html?code=${currentCode}`;
  }

  function showConnected() {
    connected = true;
    clearTimeout(rotationTimeout);
    els.pairingView.classList.add('hidden');
    els.connectedView.classList.remove('hidden');
    els.connectedLabel.textContent = 'Connected';
    els.sessionCode.textContent = currentCode;
    els.streamHint.innerHTML = `Open <a href="${captureUrl()}">capture.html</a> on this phone, then tap Live Stream on glasses.`;
    setStatus('connected', 'Linked to desktop');
  }

  function setupPeerHandlers() {
    peer.on('connection', (conn) => {
      dataConn = conn;
      conn.on('open', showConnected);
      conn.on('data', (msg) => {
        if (msg?.type === 'hello') desktopPeerId = msg.peerId;
        if (msg?.type === 'start-stream') startStream();
        if (msg?.type === 'stop-stream') stopStream();
      });
      conn.on('close', () => {
        if (connected) resetAfterDisconnect();
      });
    });

    peer.on('disconnected', () => {
      if (!connected && currentCode) {
        setStatus('error', 'Reconnecting…');
        try {
          peer.reconnect();
        } catch {
          register(currentCode, true);
        }
      }
    });

    peer.on('close', () => {
      if (!connected && currentCode && !registering) {
        register(currentCode, true);
      }
    });

    peer.on('error', (err) => {
      console.error('[caster] relay error:', err);
      if (err.type === 'unavailable-id' && !connected) {
        register(CasterSignaling.generateCode());
      } else if (!connected && currentCode) {
        setTimeout(() => register(currentCode, true), 1500);
      }
    });
  }

  async function register(code, keepVisible = false) {
    if (connected || registering) return;
    registering = true;

    if (!keepVisible) {
      els.pairCode.textContent = '······';
      els.codeTimer.textContent = 'Connecting…';
    }

    peer?.destroy();
    peer = null;

    try {
      await requestWakeLock();
      peer = CasterSignaling.createPeer(CasterSignaling.peerIdForCode(code));
      setupPeerHandlers();
      await CasterSignaling.waitForPeerOpen(peer, 30000);
      showCode(code);
      setStatus('waiting', 'Ready — enter this code on desktop');
      clearTimeout(rotationTimeout);
      rotationTimeout = setTimeout(() => {
        if (!connected) register(CasterSignaling.generateCode());
      }, ROTATION_MS);
    } catch (err) {
      console.error('[caster] register failed:', err);
      setStatus('error', 'Retrying…');
      setTimeout(() => register(code, keepVisible), 2000);
    } finally {
      registering = false;
    }
  }

  function resetAfterDisconnect() {
    connected = false;
    streaming = false;
    desktopPeerId = null;
    stopStream(false);
    dataConn = null;
    els.connectedView.classList.add('hidden');
    els.pairingView.classList.remove('hidden');
    els.streamBtn.textContent = 'Live Stream';
    els.streamBtn.classList.remove('active');
    register(currentCode, true);
  }

  async function startStream() {
    if (!desktopPeerId) return;
    stopStream(false);

    camConn?.close();
    camConn = peer.connect(CasterSignaling.camPeerIdForCode(currentCode), { reliable: true });
    try {
      await CasterSignaling.waitForConnection(camConn, 10000);
      CasterSignaling.sendData(camConn, { type: 'start-stream', desktopPeerId });
      streaming = true;
      els.streamBtn.textContent = 'Stop Stream';
      els.streamBtn.classList.add('active');
      els.streamHint.textContent = 'Casting via phone camera…';
    } catch {
      els.streamHint.innerHTML = `Open <a href="${captureUrl()}">capture.html</a> on this phone first.`;
    }
  }

  function stopStream(notify = true) {
    camConn?.close();
    camConn = null;
    if (streaming) {
      streaming = false;
      els.streamBtn.textContent = 'Live Stream';
      els.streamBtn.classList.remove('active');
      if (notify) {
        CasterSignaling.sendData(dataConn, { type: 'stop-stream' });
      }
    }
  }

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible' && peer && !peer.open && currentCode && !connected) {
      register(currentCode, true);
    }
    if (document.visibilityState === 'visible') requestWakeLock();
  });

  setInterval(() => {
    if (peer && !peer.open && !peer.destroyed && currentCode && !connected && !registering) {
      register(currentCode, true);
    }
  }, 8000);

  els.streamBtn?.addEventListener('click', () => (streaming ? stopStream() : startStream()));

  register(CasterSignaling.generateCode());
})();
