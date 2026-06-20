/**
 * Glasses web app — pairing, connected state, Live Stream control
 * Camera streams via phone capture.html when unavailable on Meta Display.
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

  const ROTATION_MS = window.CASTER_CONFIG?.CODE_ROTATION_MS || 60_000;

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
  let starting = false;

  function setStatus(kind, text) {
    els.status.className = `status ${kind}`;
    els.statusText.textContent = text;
  }

  function updateTimer() {
    const remaining = Math.max(0, Math.ceil((codeExpiresAt - Date.now()) / 1000));
    els.codeTimer.textContent = connected
      ? 'Session active'
      : remaining > 0
        ? `New code in ${remaining}s`
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

  function showConnected() {
    connected = true;
    clearTimeout(rotationTimeout);
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
    currentCode = '';
    stopStream(false);
    camConn?.close();
    camConn = null;
    dataConn = null;
    els.connectedView.classList.add('hidden');
    els.pairingView.classList.remove('hidden');
    els.streamBtn.textContent = 'Live Stream';
    els.streamBtn.classList.remove('active');
    els.streamHint.textContent = 'Cast your view to the desktop viewer.';
    setStatus('waiting', 'Waiting for pairing');
    scheduleRotation();
  }

  function destroyPeer() {
    peer?.destroy();
    peer = null;
  }

  function scheduleRotation() {
    clearTimeout(rotationTimeout);
    if (connected) return;
    rotationTimeout = setTimeout(() => {
      if (!connected) startPairingSession();
    }, ROTATION_MS);
  }

  async function startPairingSession() {
    if (connected || starting) return;
    starting = true;

    destroyPeer();
    const code = CasterSignaling.generateCode();
    els.pairCode.textContent = '······';
    els.codeTimer.textContent = 'Connecting to network…';
    setStatus('waiting', 'Starting…');

    try {
      peer = CasterSignaling.createPeer(CasterSignaling.peerIdForCode(code));

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
        if (!connected) setStatus('error', 'Reconnecting…');
      });

      peer.on('error', (err) => {
        if (err.type === 'unavailable-id') {
          starting = false;
          startPairingSession();
          return;
        }
        console.error('[caster] peer error:', err);
        if (!connected) {
          setStatus('error', 'Network error — retrying…');
          setTimeout(startPairingSession, 2000);
        }
      });

      await CasterSignaling.waitForPeerOpen(peer);
      showCode(code);
      setStatus('waiting', 'Waiting for pairing');
      scheduleRotation();
    } catch (err) {
      console.error('[caster] pairing session failed:', err);
      els.codeTimer.textContent = err.message || 'Retrying…';
      setStatus('error', 'Retrying…');
      setTimeout(startPairingSession, 2000);
    } finally {
      starting = false;
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

  startPairingSession();
})();
