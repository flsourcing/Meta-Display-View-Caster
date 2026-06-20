/**
 * Phone relay — hosts session. Desktop + glasses both connect here.
 * Keep relay.html open on your phone until glasses show Connected.
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
    captureLink: document.getElementById('capture-link'),
    networkDot: document.getElementById('network-dot'),
  };

  const ROTATION_MS = window.CASTER_CONFIG?.CODE_ROTATION_MS || 300_000;
  const REREGISTER_COOLDOWN_MS = 15000;

  let peer = null;
  let desktopConn = null;
  let glassesConn = null;
  let camConn = null;
  let desktopPeerId = null;
  let streaming = false;
  let currentCode = '';
  let codeExpiresAt = 0;
  let timerInterval = null;
  let rotationTimeout = null;
  let registering = false;
  let lastRegisterAt = 0;
  let wakeLock = null;

  function setStatus(kind, text) {
    els.status.className = `status ${kind}`;
    els.statusText.textContent = text;
  }

  function setNetworkOnline(online) {
    if (els.networkDot) {
      els.networkDot.className = online ? 'network-dot online' : 'network-dot offline';
    }
  }

  async function requestWakeLock() {
    try {
      if ('wakeLock' in navigator) {
        wakeLock?.release?.();
        wakeLock = await navigator.wakeLock.request('screen');
      }
    } catch {
      /* optional */
    }
  }

  function pageBase() {
    return location.href.replace(/[^/]*$/, '');
  }

  function updateTimer() {
    const left = Math.max(0, Math.ceil((codeExpiresAt - Date.now()) / 1000));
    const hasClients = desktopConn?.open || glassesConn?.open;
    if (hasClients) {
      els.codeTimer.textContent = 'Session active — keep this page open';
    } else {
      els.codeTimer.textContent = left > 0 ? `Code expires in ${left}s` : 'Updating code…';
    }
  }

  function showCode(code) {
    currentCode = code;
    els.pairCode.textContent = code;
    codeExpiresAt = Date.now() + ROTATION_MS;
    updateTimer();

    const base = pageBase();
    if (els.desktopLink) els.desktopLink.href = `${base}?code=${code}`;
    if (els.captureLink) els.captureLink.href = `${base}capture.html?code=${code}`;
  }

  function captureUrl() {
    return `${pageBase()}capture.html?code=${currentCode}`;
  }

  function updatePairingStatus() {
    const d = desktopConn?.open;
    const g = glassesConn?.open;
    if (d && g) {
      setStatus('connected', 'Desktop and glasses linked');
    } else if (d) {
      setStatus('waiting', 'Desktop connected — connect glasses');
    } else if (g) {
      setStatus('waiting', 'Glasses connected — connect desktop');
    } else {
      setStatus('waiting', 'Ready — enter code on desktop and glasses');
    }
  }

  function showSessionView() {
    if (!desktopConn?.open && !glassesConn?.open) {
      els.connectedView.classList.add('hidden');
      els.pairingView.classList.remove('hidden');
      updatePairingStatus();
      return;
    }
    els.pairingView.classList.add('hidden');
    els.connectedView.classList.remove('hidden');
    els.connectedLabel.textContent = desktopConn?.open && glassesConn?.open ? 'All connected' : 'Partially connected';
    els.sessionCode.textContent = currentCode;
    els.streamHint.innerHTML = `For video: open <a href="${captureUrl()}">capture.html</a> on this phone and allow camera. Then tap Live Stream on glasses.`;
    updatePairingStatus();
  }

  function handleClientData(conn, msg) {
    if (msg?.type === 'hello') {
      if (msg.role === 'desktop') {
        desktopConn = conn;
        desktopPeerId = msg.peerId || null;
        CasterSignaling.sendData(conn, { type: 'relay-ack', role: 'desktop' });
      }
      if (msg.role === 'glasses') {
        glassesConn = conn;
        CasterSignaling.sendData(conn, {
          type: 'relay-ack',
          role: 'glasses',
          desktopReady: !!desktopConn?.open,
        });
      }
      showSessionView();
      return;
    }

    if (msg?.type === 'start-stream' && conn === glassesConn) {
      startCamBridge();
      return;
    }

    if (msg?.type === 'stop-stream' && conn === glassesConn) {
      stopCamBridge(true);
    }
  }

  function setupPeerHandlers() {
    peer.on('connection', (conn) => {
      conn.on('data', (msg) => handleClientData(conn, msg));
      conn.on('close', () => {
        if (conn === desktopConn) {
          desktopConn = null;
          desktopPeerId = null;
        }
        if (conn === glassesConn) glassesConn = null;
        showSessionView();
      });
    });

    peer.on('open', () => {
      setNetworkOnline(true);
      if (currentCode) setStatus('waiting', 'Ready — enter code on desktop and glasses');
    });

    peer.on('disconnected', () => {
      setNetworkOnline(false);
      setStatus('error', 'Reconnecting relay…');
      try {
        peer.reconnect();
      } catch {
        scheduleRegister(currentCode, true);
      }
    });

    peer.on('close', () => {
      setNetworkOnline(false);
      if (currentCode && !registering) scheduleRegister(currentCode, true);
    });

    peer.on('error', (err) => {
      console.error('[caster] relay error:', err);
      setNetworkOnline(false);
      if (err.type === 'unavailable-id' && !desktopConn?.open && !glassesConn?.open) {
        register(CasterSignaling.generateCode());
      } else if (currentCode) {
        scheduleRegister(currentCode, true);
      }
    });
  }

  function scheduleRegister(code, keepVisible) {
    const elapsed = Date.now() - lastRegisterAt;
    const delay = Math.max(0, REREGISTER_COOLDOWN_MS - elapsed);
    setTimeout(() => register(code, keepVisible), delay);
  }

  async function register(code, keepVisible = false) {
    if (registering) return;
    if ((desktopConn?.open || glassesConn?.open) && keepVisible) return;

    registering = true;
    lastRegisterAt = Date.now();

    if (!keepVisible) {
      els.pairCode.textContent = '······';
      els.codeTimer.textContent = 'Starting relay…';
    }

    desktopConn = null;
    glassesConn = null;
    desktopPeerId = null;
    peer?.destroy();
    peer = null;

    try {
      await requestWakeLock();
      peer = CasterSignaling.createPeer(CasterSignaling.peerIdForCode(code));
      setupPeerHandlers();
      await CasterSignaling.waitForPeerOpen(peer, 30000);
      showCode(code);
      setNetworkOnline(true);
      setStatus('waiting', 'Ready — enter code on desktop and glasses');
      clearTimeout(rotationTimeout);
      rotationTimeout = setTimeout(() => {
        if (!desktopConn?.open && !glassesConn?.open) register(CasterSignaling.generateCode());
      }, ROTATION_MS);
    } catch (err) {
      console.error('[caster] register failed:', err);
      setNetworkOnline(false);
      setStatus('error', 'Retrying relay…');
      scheduleRegister(code, keepVisible);
    } finally {
      registering = false;
    }
  }

  async function startCamBridge() {
    if (!desktopPeerId) {
      CasterSignaling.sendData(glassesConn, { type: 'stop-stream' });
      return;
    }

    camConn?.close();
    camConn = peer.connect(CasterSignaling.camPeerIdForCode(currentCode), { reliable: true });
    try {
      await CasterSignaling.waitForConnection(camConn, 15000);
      CasterSignaling.sendData(camConn, { type: 'start-stream', desktopPeerId });
      streaming = true;
      CasterSignaling.sendData(glassesConn, { type: 'stream-started' });
      CasterSignaling.sendData(desktopConn, { type: 'stream-started' });
      els.streamHint.textContent = 'Casting via phone camera…';
    } catch {
      els.streamHint.innerHTML = `Open <a href="${captureUrl()}">capture.html</a> on this phone and allow camera access.`;
      CasterSignaling.sendData(glassesConn, { type: 'stop-stream' });
    }
  }

  function stopCamBridge(notify = true) {
    if (camConn?.open) CasterSignaling.sendData(camConn, { type: 'stop-stream' });
    camConn?.close();
    camConn = null;
    if (streaming) {
      streaming = false;
      if (notify) {
        CasterSignaling.sendData(glassesConn, { type: 'stop-stream' });
        CasterSignaling.sendData(desktopConn, { type: 'stop-stream' });
      }
      els.streamHint.innerHTML = `For video: open <a href="${captureUrl()}">capture.html</a> on this phone and allow camera.`;
    }
  }

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') {
      requestWakeLock();
      if (peer && !peer.open && currentCode) scheduleRegister(currentCode, true);
    }
  });

  if (!timerInterval) timerInterval = setInterval(updateTimer, 1000);

  if (els.keepOpenHint) {
    els.keepOpenHint.textContent = 'Keep this page open until glasses show Connected. Pairing does not need camera — camera is only for capture.html when streaming.';
  }

  register(CasterSignaling.generateCode());
})();
