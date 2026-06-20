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

  let ws = null;
  let pc = null;
  let localStream = null;
  let connected = false;
  let codeExpiresAt = 0;
  let timerInterval = null;

  function setStatus(kind, text) {
    els.status.className = `status ${kind}`;
    els.statusText.textContent = text;
  }

  function updateTimer() {
    const remaining = Math.max(0, Math.ceil((codeExpiresAt - Date.now()) / 1000));
    els.codeTimer.textContent = remaining > 0
      ? `New code in ${remaining}s`
      : 'Updating code…';
  }

  function showCode(code, expiresIn) {
    els.pairCode.textContent = code;
    codeExpiresAt = Date.now() + (expiresIn || 60000);
    updateTimer();
    if (!timerInterval) {
      timerInterval = setInterval(updateTimer, 1000);
    }
  }

  function showConnected() {
    connected = true;
    els.pairingView.classList.add('hidden');
    els.connectedView.classList.remove('hidden');
    els.connectedLabel.textContent = 'Connected';
    setStatus('connected', 'Linked to desktop');
  }

  function showPairing() {
    connected = false;
    stopStream();
    els.connectedView.classList.add('hidden');
    els.pairingView.classList.remove('hidden');
    setStatus('waiting', 'Waiting for pairing');
  }

  async function startStream() {
    if (pc) return;

    try {
      localStream = await navigator.mediaDevices.getUserMedia({
        video: { facingMode: 'environment', width: { ideal: 1280 }, height: { ideal: 720 } },
        audio: false,
      });
    } catch (err) {
      console.error('[caster] camera unavailable:', err);
      els.streamHint.textContent = 'Camera unavailable on this device.';
      CasterSignaling.send(ws, { type: 'stop-stream' });
      return;
    }

    pc = CasterSignaling.createPeerConnection(
      null,
      (candidate) => {
        CasterSignaling.send(ws, { type: 'ice-candidate', candidate });
      }
    );

    localStream.getTracks().forEach((track) => pc.addTrack(track, localStream));

    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    CasterSignaling.send(ws, { type: 'offer', offer: pc.localDescription });

    els.streamHint.textContent = 'Streaming live view…';
  }

  function stopStream() {
    localStream?.getTracks().forEach((t) => t.stop());
    localStream = null;
    pc?.close();
    pc = null;
    els.streamHint.textContent = 'Tap Live Stream on your desktop to begin.';
  }

  async function handleMessage(msg) {
    switch (msg.type) {
      case 'registered':
      case 'session':
        if (msg.code) showCode(msg.code, msg.expiresIn);
        if (msg.paired) showConnected();
        else if (!connected) showPairing();
        break;

      case 'paired':
        showConnected();
        break;

      case 'disconnected':
        showPairing();
        break;

      case 'start-stream':
        await startStream();
        break;

      case 'stop-stream':
        stopStream();
        break;

      case 'answer':
        if (pc && msg.answer) {
          await pc.setRemoteDescription(new RTCSessionDescription(msg.answer));
        }
        break;

      case 'ice-candidate':
        if (pc && msg.candidate) {
          pc.addIceCandidate(new RTCIceCandidate(msg.candidate)).catch(console.error);
        }
        break;

      case 'error':
        console.error('[caster]', msg.message);
        break;
    }
  }

  function register() {
    try {
      ws = CasterSignaling.createSignalingConnection(handleMessage, () => {
        setStatus('error', 'Reconnecting…');
        setTimeout(register, 3000);
      });

      ws.addEventListener('open', () => {
        setStatus('waiting', 'Waiting for pairing');
        CasterSignaling.send(ws, { type: 'register-glasses' });
      });
    } catch (err) {
      setStatus('error', 'Server not configured');
      els.pairCode.textContent = '----';
      els.codeTimer.textContent = err.message;
    }
  }

  register();
})();
