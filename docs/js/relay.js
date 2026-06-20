/**
 * Phone relay — hosts the pairing session (use when Meta glasses can't register).
 * Open this on your phone FIRST, then enter the code on desktop.
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
  };

  const ROTATION_MS = window.CASTER_CONFIG?.CODE_ROTATION_MS || 300_000;

  let peer = null;
  let dataConn = null;
  let camConn = null;
  let localStream = null;
  let activeCall = null;
  let connected = false;
  let streaming = false;
  let desktopPeerId = null;
  let currentCode = '';
  let codeExpiresAt = 0;
  let timerInterval = null;
  let rotationTimeout = null;
  let busy = false;

  function setStatus(kind, text) {
    els.status.className = `status ${kind}`;
    els.statusText.textContent = text;
  }

  function updateTimer() {
    const left = Math.max(0, Math.ceil((codeExpiresAt - Date.now()) / 1000));
    els.codeTimer.textContent = connected ? 'Session active' : left > 0 ? `Code expires in ${left}s` : 'New code…';
  }

  function showCode(code) {
    currentCode = code;
    els.pairCode.textContent = code;
    codeExpiresAt = Date.now() + ROTATION_MS;
    updateTimer();
    if (!timerInterval) timerInterval = setInterval(updateTimer, 1000);
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

  function attachListeners() {
    peer.on('connection', (conn) => {
      dataConn = conn;
      conn.on('open', showConnected);
      conn.on('data', (msg) => {
        if (msg?.type === 'hello') desktopPeerId = msg.peerId;
        if (msg?.type === 'start-stream') startStream();
        if (msg?.type === 'stop-stream') stopStream();
      });
      conn.on('close', () => { if (connected) resetSession(); });
    });

    peer.on('disconnected', () => {
      if (!connected && currentCode) register(currentCode, true);
    });
  }

  async function register(code, keepVisible = false) {
    if (connected || busy) return;
    busy = true;
    peer?.destroy();
    if (!keepVisible) {
      els.pairCode.textContent = '······';
      els.codeTimer.textContent = 'Connecting…';
    }
    try {
      peer = await CasterSignaling.createPeerWithRetry(CasterSignaling.peerIdForCode(code));
      attachListeners();
      showCode(code);
      setStatus('waiting', 'Ready — enter this code on desktop');
      clearTimeout(rotationTimeout);
      rotationTimeout = setTimeout(() => { if (!connected) register(CasterSignaling.generateCode()); }, ROTATION_MS);
    } catch (err) {
      console.error(err);
      setStatus('error', 'Retrying…');
      setTimeout(() => register(code, keepVisible), 2000);
    } finally {
      busy = false;
    }
  }

  function resetSession() {
    connected = false;
    streaming = false;
    desktopPeerId = null;
    stopStream(false);
    dataConn = null;
    els.connectedView.classList.add('hidden');
    els.pairingView.classList.remove('hidden');
    els.streamBtn.textContent = 'Live Stream';
    els.streamBtn.classList.remove('active');
    register(currentCode || CasterSignaling.generateCode(), true);
  }

  async function startStream() {
    if (!desktopPeerId) return;
    stopStream(false);

    camConn?.close();
    camConn = peer.connect(CasterSignaling.camPeerIdForCode(currentCode), { reliable: true });
    try {
      await CasterSignaling.waitForConnection(camConn, 8000);
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
    activeCall?.close();
    activeCall = null;
    localStream?.getTracks().forEach((t) => t.stop());
    localStream = null;
    camConn?.close();
    camConn = null;
    if (streaming) {
      streaming = false;
      els.streamBtn.textContent = 'Live Stream';
      els.streamBtn.classList.remove('active');
      if (notify) CasterSignaling.sendData(camConn, { type: 'stop-stream' });
      CasterSignaling.sendData(dataConn, { type: 'stop-stream' });
    }
  }

  els.streamBtn?.addEventListener('click', () => streaming ? stopStream() : startStream());

  register(CasterSignaling.generateCode());
})();
