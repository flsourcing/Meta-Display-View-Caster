/**
 * Glasses web app — pairing, connected state, Live Stream control
 */

(function () {
  const CAPTURE_PAGE = 'capture.html';

  const els = {
    pairingView: document.getElementById('pairing-view'),
    connectedView: document.getElementById('connected-view'),
    pairCode: document.getElementById('pair-code'),
    codeTimer: document.getElementById('code-timer'),
    status: document.getElementById('status'),
    statusText: document.getElementById('status-text'),
    connectedLabel: document.getElementById('connected-label'),
    streamHint: document.getElementById('stream-hint'),
    streamBtn: document.getElementById('stream-btn'),
    sessionCode: document.getElementById('session-code'),
  };

  const ROTATION_MS = window.CASTER_CONFIG?.CODE_ROTATION_MS || 180_000;

  let peer = null;
  let dataConn = null;
  let camConn = null;
  let localStream = null;
  let activeCall = null;
  let connected = false;
  let streaming = false;
  let usingPhoneCamera = false;
  let desktopPeerId = null;
  let currentCode = '';
  let codeExpiresAt = 0;
  let timerInterval = null;
  let rotationTimeout = null;
  let registering = false;
  let reconnectTimer = null;

  function setStatus(kind, text) {
    els.status.className = `status ${kind}`;
    els.statusText.textContent = text;
  }

  function updateTimer() {
    const remaining = Math.max(0, Math.ceil((codeExpiresAt - Date.now()) / 1000));
    els.codeTimer.textContent = connected
      ? 'Session active'
      : remaining > 0
        ? `Code expires in ${remaining}s`
        : 'Updating code…';
  }

  function showCode(code) {
    currentCode = code;
    els.pairCode.textContent = code;
    codeExpiresAt = Date.now() + ROTATION_MS;
    updateTimer();
    if (!timerInterval) {
      timerInterval = setInterval(updateTimer, 1000);
    }
  }

  function phoneCaptureHint() {
    return `Open ${CAPTURE_PAGE} on your phone with code ${currentCode}, then tap Live Stream here.`;
  }

  function attachPeerListeners() {
    peer.on('connection', (conn) => {
      dataConn = conn;

      conn.on('open', () => {
        showConnected();
      });

      conn.on('data', (msg) => {
        if (msg?.type === 'hello' && msg.peerId) {
          desktopPeerId = msg.peerId;
        } else if (msg?.type === 'stream-started' && usingPhoneCamera) {
          streaming = true;
          els.streamBtn.textContent = 'Stop Stream';
          els.streamBtn.classList.add('active');
          els.streamHint.textContent = 'Casting to desktop viewer…';
        } else if (msg?.type === 'stop-stream' && usingPhoneCamera) {
          stopStream(false);
        }
      });

      conn.on('close', () => {
        if (connected) showPairing();
      });
    });

    peer.on('disconnected', () => {
      if (connected) return;
      setStatus('error', 'Reconnecting…');
      scheduleReconnect(currentCode);
    });

    peer.on('close', () => {
      if (!connected && currentCode) {
        scheduleReconnect(currentCode);
      }
    });

    peer.on('error', (err) => {
      if (err.type === 'unavailable-id') {
        registerCode(CasterSignaling.generateCode());
        return;
      }
      console.error('[caster] peer error:', err);
      if (!connected && currentCode) {
        setStatus('error', 'Network error — reconnecting…');
        scheduleReconnect(currentCode);
      }
    });
  }

  function scheduleReconnect(code) {
    clearTimeout(reconnectTimer);
    reconnectTimer = setTimeout(() => {
      if (!connected && code) registerCode(code, true);
    }, 1500);
  }

  function showConnected() {
    connected = true;
    clearTimeout(rotationTimeout);
    clearTimeout(reconnectTimer);
    els.pairingView.classList.add('hidden');
    els.connectedView.classList.remove('hidden');
    els.connectedLabel.textContent = 'Connected';
    els.sessionCode.textContent = currentCode;
    setStatus('connected', 'Linked to desktop');
    updateTimer();
    els.streamHint.textContent = phoneCaptureHint();
    els.streamBtn.focus();
  }

  function showPairing() {
    connected = false;
    streaming = false;
    usingPhoneCamera = false;
    desktopPeerId = null;
    stopStream(false);
    camConn?.close();
    camConn = null;
    dataConn = null;
    els.connectedView.classList.add('hidden');
    els.pairingView.classList.remove('hidden');
    els.streamBtn.textContent = 'Live Stream';
    els.streamBtn.classList.remove('active');
    els.streamHint.textContent = 'Cast your view to the desktop viewer.';
    if (currentCode) {
      registerCode(currentCode, true);
    } else {
      registerCode(CasterSignaling.generateCode());
    }
  }

  function destroyPeer() {
    peer?.destroy();
    peer = null;
  }

  function scheduleRotation() {
    clearTimeout(rotationTimeout);
    if (connected) return;
    rotationTimeout = setTimeout(() => {
      if (!connected) registerCode(CasterSignaling.generateCode());
    }, ROTATION_MS);
  }

  async function registerCode(code, keepCodeVisible = false) {
    if (connected || registering) return;
    registering = true;
    clearTimeout(reconnectTimer);

    if (!keepCodeVisible) {
      els.pairCode.textContent = '······';
      els.codeTimer.textContent = 'Connecting to network…';
      setStatus('waiting', 'Starting…');
    } else {
      setStatus('waiting', 'Reconnecting…');
    }

    destroyPeer();

    try {
      peer = await CasterSignaling.createPeerWithFallback(CasterSignaling.peerIdForCode(code));
      attachPeerListeners();
      showCode(code);
      setStatus('waiting', 'Ready — enter this code on desktop');
      scheduleRotation();
    } catch (err) {
      console.error('[caster] register failed:', err);
      els.codeTimer.textContent = err.message || 'Retrying…';
      setStatus('error', 'Retrying…');
      scheduleReconnect(code);
    } finally {
      registering = false;
    }
  }

  async function streamFromLocalCamera() {
    localStream = await navigator.mediaDevices.getUserMedia({
      video: { facingMode: 'environment', width: { ideal: 1280 }, height: { ideal: 720 } },
      audio: false,
    });

    activeCall = peer.call(desktopPeerId, localStream);
    activeCall.on('close', () => {
      if (streaming && !usingPhoneCamera) toggleStream();
    });

    usingPhoneCamera = false;
    streaming = true;
    els.streamBtn.textContent = 'Stop Stream';
    els.streamBtn.classList.add('active');
    els.streamHint.textContent = 'Casting to desktop viewer…';
    CasterSignaling.sendData(dataConn, { type: 'stream-started' });
  }

  async function streamFromPhone() {
    usingPhoneCamera = true;
    els.streamHint.textContent = 'Starting phone camera…';

    camConn?.close();
    camConn = peer.connect(CasterSignaling.camPeerIdForCode(currentCode), { reliable: true });

    try {
      await CasterSignaling.waitForConnection(camConn, 10000);
    } catch {
      usingPhoneCamera = false;
      els.streamHint.textContent = phoneCaptureHint();
      throw new Error('Phone camera not ready.');
    }

    camConn.on('data', (msg) => {
      if (msg?.type === 'stream-started') {
        streaming = true;
        els.streamBtn.textContent = 'Stop Stream';
        els.streamBtn.classList.add('active');
        els.streamHint.textContent = 'Casting to desktop viewer…';
        CasterSignaling.sendData(dataConn, { type: 'stream-started' });
      } else if (msg?.type === 'stream-error') {
        usingPhoneCamera = false;
        els.streamHint.textContent = msg.message || phoneCaptureHint();
      }
    });

    camConn.on('close', () => {
      if (streaming && usingPhoneCamera) stopStream(true);
    });

    CasterSignaling.sendData(camConn, { type: 'start-stream', desktopPeerId });
  }

  async function startStream() {
    if (!desktopPeerId || !peer) {
      els.streamHint.textContent = 'Desktop not ready yet. Reconnect from the viewer page.';
      return;
    }

    stopStream(false);

    try {
      if (CasterSignaling.hasCameraSupport()) {
        try {
          await streamFromLocalCamera();
          return;
        } catch (err) {
          console.warn('[caster] local camera failed, using phone relay:', err);
        }
      }
      await streamFromPhone();
    } catch (err) {
      console.error('[caster] stream failed:', err);
      usingPhoneCamera = false;
      streaming = false;
      els.streamBtn.textContent = 'Live Stream';
      els.streamBtn.classList.remove('active');
      els.streamHint.textContent = phoneCaptureHint();
      CasterSignaling.sendData(dataConn, { type: 'stop-stream' });
    }
  }

  function stopStream(notifyDesktop = true) {
    activeCall?.close();
    activeCall = null;
    localStream?.getTracks().forEach((t) => t.stop());
    localStream = null;

    if (usingPhoneCamera && camConn?.open) {
      CasterSignaling.sendData(camConn, { type: 'stop-stream' });
    }
    camConn?.close();
    camConn = null;

    if (streaming || usingPhoneCamera) {
      streaming = false;
      usingPhoneCamera = false;
      els.streamBtn.textContent = 'Live Stream';
      els.streamBtn.classList.remove('active');
      els.streamHint.textContent = phoneCaptureHint();
      if (notifyDesktop) {
        CasterSignaling.sendData(dataConn, { type: 'stop-stream' });
      }
    }
  }

  function toggleStream() {
    if (!connected) return;
    if (streaming) {
      stopStream(true);
    } else {
      startStream();
    }
  }

  els.streamBtn.addEventListener('click', toggleStream);
  els.streamBtn.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') toggleStream();
  });

  registerCode(CasterSignaling.generateCode());
})();
