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
    relayHint: document.getElementById('relay-hint'),
  };

  const ROTATION_MS = window.CASTER_CONFIG?.CODE_ROTATION_MS || 300_000;
  const REREGISTER_COOLDOWN_MS = 15000;

  let peer = null;
  let desktopConn = null;
  let glassesConn = null;
  let camConn = null;
  let desktopPeerId = null;
  let localStream = null;
  let activeCall = null;
  let streaming = false;
  let currentCode = '';
  let codeExpiresAt = 0;
  let timerInterval = null;
  let rotationTimeout = null;
  let registering = false;
  let lastRegisterAt = 0;
  let wakeLock = null;
  let connectingDesktop = false;
  let desktopPollInterval = null;

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
    if (els.relayHint) {
      els.relayHint.textContent = `Relay ID: ${CasterSignaling.peerIdForCode(code)}`;
    }
  }

  function bindDesktopConn(conn) {
    conn.on('close', () => {
      if (conn === desktopConn) {
        desktopConn = null;
        desktopPeerId = null;
        showSessionView();
      }
    });
  }

  async function tryConnectDesktop() {
    if (connectingDesktop || desktopConn?.open || !peer?.open || !currentCode) return;
    connectingDesktop = true;
    let conn;
    const prevStatus = els.statusText?.textContent;
    try {
      if (!glassesConn?.open) setStatus('waiting', 'Linking to desktop…');
      conn = peer.connect(CasterSignaling.desktopPeerIdForCode(currentCode), { reliable: true });
      await CasterSignaling.waitForConnection(conn, 12000);
      CasterSignaling.sendData(conn, { type: 'hello', role: 'phone-relay', code: currentCode });
      await CasterSignaling.waitForRelayAck(conn, 10000);
      desktopConn = conn;
      desktopPeerId = CasterSignaling.desktopPeerIdForCode(currentCode);
      bindDesktopConn(conn);
      showSessionView();
      setStatus('connected', 'Desktop connected — connect glasses');
    } catch {
      try { conn?.close?.(); } catch { /* ignore */ }
      if (!desktopConn?.open && !glassesConn?.open && prevStatus) {
        setStatus('waiting', 'Ready — tap Connect on desktop');
      }
    } finally {
      connectingDesktop = false;
    }
  }

  function startDesktopPolling() {
    if (desktopPollInterval) return;
    tryConnectDesktop();
    desktopPollInterval = setInterval(tryConnectDesktop, 1000);
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
    els.streamHint.innerHTML = 'Tap <strong>Live Stream</strong> on glasses to cast to desktop.';
    updatePairingStatus();
  }

  function handleClientData(conn, msg) {
    if (msg?.type === 'hello') {
      if (msg.role === 'desktop') {
        desktopConn = conn;
        desktopPeerId = msg.peerId || CasterSignaling.desktopPeerIdForCode(currentCode);
        bindDesktopConn(conn);
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
      if (currentCode) {
        setStatus('waiting', 'Ready — enter code on desktop and glasses');
        tryConnectDesktop();
        startDesktopPolling();
      }
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
      } else if (currentCode && peer && !peer.destroyed) {
        try {
          peer.reconnect();
        } catch {
          scheduleRegister(currentCode, true);
        }
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
    if (peer?.open && currentCode === code) {
      setNetworkOnline(true);
      showCode(code);
      setStatus('waiting', 'Ready — enter code on desktop and glasses');
      return;
    }
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
      tryConnectDesktop();
      startDesktopPolling();
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

  async function startInlineStream(targetId) {
    if (!navigator.mediaDevices?.getUserMedia) return false;
    stopInlineStream(false);
    try {
      localStream = await navigator.mediaDevices.getUserMedia({
        video: { facingMode: 'environment', width: { ideal: 1280 }, height: { ideal: 720 } },
        audio: false,
      });
      activeCall = peer.call(targetId, localStream);
      activeCall.on('close', () => stopInlineStream(true));
      return true;
    } catch {
      stopInlineStream(false);
      return false;
    }
  }

  function stopInlineStream(notify = true) {
    activeCall?.close();
    activeCall = null;
    localStream?.getTracks().forEach((t) => t.stop());
    localStream = null;
    if (streaming && notify) {
      streaming = false;
      CasterSignaling.sendData(glassesConn, { type: 'stop-stream' });
      CasterSignaling.sendData(desktopConn, { type: 'stop-stream' });
      if (els.streamHint) {
        els.streamHint.textContent = 'Tap Live Stream on glasses to cast again.';
      }
    }
  }

  async function startCamBridge() {
    const targetId = desktopPeerId || CasterSignaling.desktopPeerIdForCode(currentCode);
    if (!targetId) {
      CasterSignaling.sendData(glassesConn, { type: 'stop-stream' });
      return;
    }

    if (await startInlineStream(targetId)) {
      streaming = true;
      CasterSignaling.sendData(glassesConn, { type: 'stream-started' });
      CasterSignaling.sendData(desktopConn, { type: 'stream-started' });
      if (els.streamHint) els.streamHint.textContent = 'Live stream casting to desktop…';
      return;
    }

    camConn?.close();
    camConn = peer.connect(CasterSignaling.camPeerIdForCode(currentCode), { reliable: true });
    try {
      await CasterSignaling.waitForConnection(camConn, 15000);
      CasterSignaling.sendData(camConn, { type: 'start-stream', desktopPeerId: targetId });
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
    stopInlineStream(false);
    if (camConn?.open) CasterSignaling.sendData(camConn, { type: 'stop-stream' });
    camConn?.close();
    camConn = null;
    if (streaming) {
      streaming = false;
      if (notify) {
        CasterSignaling.sendData(glassesConn, { type: 'stop-stream' });
        CasterSignaling.sendData(desktopConn, { type: 'stop-stream' });
      }
      if (els.streamHint) {
        els.streamHint.textContent = 'Tap Live Stream on glasses to cast again.';
      }
    }
  }

  function startRelay() {
    if (registering || peer?.open) return;
    register(CasterSignaling.generateCode());
  }

  function restartRelay() {
    stopInlineStream(false);
    stopCamBridge(false);
    register(CasterSignaling.generateCode());
  }

  window.CasterRelay = { start: startRelay, restart: restartRelay };

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') {
      requestWakeLock();
      if (peer && !peer.open && currentCode) scheduleRegister(currentCode, true);
    }
  });

  if (!timerInterval) timerInterval = setInterval(updateTimer, 1000);

  if (els.keepOpenHint) {
    els.keepOpenHint.textContent = 'Keep this app open. Enter the code on glasses, then tap Live Stream to cast to desktop.';
  }

  setInterval(() => {
    if (peer && !peer.open && !peer.destroyed && !registering && currentCode) {
      try {
        peer.reconnect();
      } catch {
        scheduleRegister(currentCode, true);
      }
    }
  }, 4000);

  if (document.getElementById('ready-view') && document.getElementById('setup-view')) {
    /* phone.html — phone-setup.js starts relay after onboarding */
  } else {
    register(CasterSignaling.generateCode());
  }
})();
