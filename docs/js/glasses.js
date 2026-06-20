/**
 * Glasses — pairing, connected state, Live Stream control
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

  let ws = null;
  let pc = null;
  let localStream = null;
  let connected = false;
  let streaming = false;
  let captureReady = false;
  let currentCode = '';
  let codeExpiresAt = 0;
  let timerInterval = null;

  function setStatus(kind, text) {
    els.status.className = `status ${kind}`;
    els.statusText.textContent = text;
  }

  function updateTimer() {
    const remaining = Math.max(0, Math.ceil((codeExpiresAt - Date.now()) / 1000));
    els.codeTimer.textContent = connected
      ? 'Session active'
      : remaining > 0 ? `Code expires in ${remaining}s` : 'Updating code…';
  }

  function showCode(code, expiresIn) {
    currentCode = code;
    els.pairCode.textContent = code;
    codeExpiresAt = Date.now() + (expiresIn || 180000);
    updateTimer();
    if (!timerInterval) timerInterval = setInterval(updateTimer, 1000);
  }

  function phoneHint() {
    return `Open ${CAPTURE_PAGE}?code=${currentCode} on your phone, then tap Live Stream.`;
  }

  function showConnected() {
    connected = true;
    els.pairingView.classList.add('hidden');
    els.connectedView.classList.remove('hidden');
    els.connectedLabel.textContent = 'Connected';
    els.sessionCode.textContent = currentCode;
    els.streamHint.textContent = phoneHint();
    setStatus('connected', 'Linked to desktop');
    els.streamBtn.focus();
  }

  function showPairing() {
    connected = false;
    streaming = false;
    captureReady = false;
    stopStream(false);
    els.connectedView.classList.add('hidden');
    els.pairingView.classList.remove('hidden');
    els.streamBtn.textContent = 'Live Stream';
    els.streamBtn.classList.remove('active');
    setStatus('waiting', 'Waiting for pairing');
  }

  function handleMessage(msg) {
    switch (msg.type) {
      case 'registered':
      case 'session':
        if (msg.code) showCode(msg.code, msg.expiresIn);
        if (msg.paired) showConnected();
        else setStatus('waiting', 'Ready — enter this code on desktop');
        break;
      case 'paired':
        showConnected();
        break;
      case 'disconnected':
        showPairing();
        break;
      case 'capture-ready':
        captureReady = true;
        if (connected) els.streamHint.textContent = 'Phone camera ready. Tap Live Stream.';
        break;
      case 'capture-offline':
        captureReady = false;
        if (connected) els.streamHint.textContent = phoneHint();
        break;
      case 'start-stream':
        startStream(msg.source || 'local');
        break;
      case 'stop-stream':
        stopStream(false);
        break;
      case 'answer':
        if (pc && msg.answer) pc.setRemoteDescription(new RTCSessionDescription(msg.answer)).catch(console.error);
        break;
      case 'ice-candidate':
        if (pc && msg.candidate) pc.addIceCandidate(new RTCIceCandidate(msg.candidate)).catch(console.error);
        break;
      case 'error':
        console.error('[caster]', msg.message);
        break;
    }
  }

  function connect() {
    CasterSignaling.wakeServer();
    ws = CasterSignaling.createSignalingConnection(handleMessage, () => {
      if (!connected) {
        setStatus('error', 'Reconnecting…');
        setTimeout(connect, 2000);
      }
    });
    ws.addEventListener('open', () => {
      CasterSignaling.send(ws, { type: 'register-glasses' });
    });
  }

  async function streamLocal() {
    localStream = await navigator.mediaDevices.getUserMedia({
      video: { facingMode: 'environment', width: { ideal: 1280 }, height: { ideal: 720 } },
      audio: false,
    });
    pc = CasterSignaling.createPeerConnection(null, (c) => CasterSignaling.send(ws, { type: 'ice-candidate', candidate: c }));
    localStream.getTracks().forEach((t) => pc.addTrack(t, localStream));
    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    CasterSignaling.send(ws, { type: 'offer', offer: pc.localDescription });
    streaming = true;
    els.streamBtn.textContent = 'Stop Stream';
    els.streamBtn.classList.add('active');
    els.streamHint.textContent = 'Casting to desktop…';
    CasterSignaling.send(ws, { type: 'stream-started' });
  }

  async function startStream() {
    stopStream(false);
    try {
      if (CasterSignaling.hasCameraSupport()) {
        try {
          await streamLocal();
          return;
        } catch (err) {
          console.warn('[caster] local camera unavailable:', err);
        }
      }
      if (!captureReady) {
        els.streamHint.textContent = phoneHint();
        return;
      }
      CasterSignaling.send(ws, { type: 'start-stream', source: 'capture' });
      streaming = true;
      els.streamBtn.textContent = 'Stop Stream';
      els.streamBtn.classList.add('active');
      els.streamHint.textContent = 'Starting phone camera…';
    } catch (err) {
      console.error('[caster] stream failed:', err);
      els.streamHint.textContent = phoneHint();
    }
  }

  function stopStream(notify) {
    localStream?.getTracks().forEach((t) => t.stop());
    localStream = null;
    pc?.close();
    pc = null;
    if (streaming) {
      streaming = false;
      els.streamBtn.textContent = 'Live Stream';
      els.streamBtn.classList.remove('active');
      els.streamHint.textContent = connected ? phoneHint() : 'Cast your view to the desktop viewer.';
      if (notify !== false) CasterSignaling.send(ws, { type: 'stop-stream' });
    }
  }

  function toggleStream() {
    if (!connected) return;
    streaming ? stopStream(true) : startStream();
  }

  els.streamBtn.addEventListener('click', toggleStream);
  els.streamBtn.addEventListener('keydown', (e) => { if (e.key === 'Enter') toggleStream(); });

  connect();
})();
