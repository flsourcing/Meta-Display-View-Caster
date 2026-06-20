/**
 * Glasses web app — display pairing code, show connected state, stream camera on request
 */

(function () {
  const els = {
    pairingView: document.getElementById('pairing-view'),
    connectedView: document.getElementById('connected-view'),
    pairCode: document.getElementById('pair-code'),
    codeTimer: document.getElementById('code-timer'),
    status: document.getElementById('status'),
    statusText: document.getElementById('status-text'),
    connectedLabel: document.getElementById('connected-label'),
    streamHint: document.getElementById('stream-hint'),
  };

  const ROTATION_MS = window.CASTER_CONFIG?.CODE_ROTATION_MS || 60_000;

  let peer = null;
  let dataConn = null;
  let localStream = null;
  let activeCall = null;
  let connected = false;
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

  function showConnected() {
    connected = true;
    clearTimeout(rotationTimeout);
    els.pairingView.classList.add('hidden');
    els.connectedView.classList.remove('hidden');
    els.connectedLabel.textContent = 'Connected';
    setStatus('connected', 'Linked to desktop');
    updateTimer();
  }

  function showPairing() {
    connected = false;
    stopStream();
    dataConn = null;
    els.connectedView.classList.add('hidden');
    els.pairingView.classList.remove('hidden');
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

        conn.on('data', async (msg) => {
          if (msg?.type === 'start-stream') {
            await startStream(msg.peerId);
          } else if (msg?.type === 'stop-stream') {
            stopStream();
          }
        });

        conn.on('close', () => {
          if (connected) showPairing();
        });
      });

      peer.on('disconnected', () => {
        if (!connected) {
          setStatus('error', 'Reconnecting…');
        }
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

  async function startStream(desktopPeerId) {
    stopStream();

    try {
      localStream = await navigator.mediaDevices.getUserMedia({
        video: { facingMode: 'environment', width: { ideal: 1280 }, height: { ideal: 720 } },
        audio: false,
      });
    } catch (err) {
      console.error('[caster] camera unavailable:', err);
      els.streamHint.textContent = 'Camera unavailable on this device.';
      CasterSignaling.sendData(dataConn, { type: 'stop-stream' });
      return;
    }

    activeCall = peer.call(desktopPeerId, localStream);
    activeCall.on('close', stopStream);
    els.streamHint.textContent = 'Streaming live view…';
  }

  function stopStream() {
    activeCall?.close();
    activeCall = null;
    localStream?.getTracks().forEach((t) => t.stop());
    localStream = null;
    els.streamHint.textContent = 'Tap Live Stream on your desktop to begin.';
  }

  startPairingSession();
})();
