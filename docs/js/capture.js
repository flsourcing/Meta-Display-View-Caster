/**
 * Phone camera bridge — streams to desktop via signaling server
 */

(function () {
  const els = {
    codeInput: document.getElementById('code-input'),
    connectBtn: document.getElementById('connect-btn'),
    status: document.getElementById('status'),
    statusText: document.getElementById('status-text'),
    errorMsg: document.getElementById('error-msg'),
    readyView: document.getElementById('ready-view'),
    codeDisplay: document.getElementById('code-display'),
  };

  let ws = null;
  let pc = null;
  let localStream = null;
  let ready = false;
  let streaming = false;

  function setStatus(kind, text) {
    els.status.className = `status ${kind}`;
    els.statusText.textContent = text;
  }

  function showError(msg) {
    els.errorMsg.textContent = msg || '';
    els.errorMsg.classList.toggle('error', !!msg);
  }

  function stopStream() {
    localStream?.getTracks().forEach((t) => t.stop());
    localStream = null;
    pc?.close();
    pc = null;
    streaming = false;
    if (ready) setStatus('connected', 'Ready — tap Live Stream on glasses');
  }

  async function startStream() {
    stopStream();
    setStatus('waiting', 'Starting camera…');

    try {
      localStream = await navigator.mediaDevices.getUserMedia({
        video: { facingMode: 'environment', width: { ideal: 1280 }, height: { ideal: 720 } },
        audio: false,
      });
    } catch (err) {
      console.error('[caster] camera failed:', err);
      CasterSignaling.send(ws, { type: 'stream-error', message: 'Allow camera access on your phone.' });
      setStatus('error', 'Camera permission denied');
      return;
    }

    pc = CasterSignaling.createPeerConnection(null, (c) => CasterSignaling.send(ws, { type: 'ice-candidate', candidate: c }));
    localStream.getTracks().forEach((t) => pc.addTrack(t, localStream));
    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    CasterSignaling.send(ws, { type: 'offer', offer: pc.localDescription });
    streaming = true;
    setStatus('connected', 'Live stream active');
    CasterSignaling.send(ws, { type: 'stream-started' });
  }

  function handleMessage(msg) {
    switch (msg.type) {
      case 'registered':
        ready = true;
        els.codeDisplay.textContent = msg.code || els.codeInput.value;
        els.readyView.classList.remove('hidden');
        els.connectBtn.classList.add('hidden');
        els.codeInput.disabled = true;
        setStatus('connected', 'Ready — tap Live Stream on glasses');
        showError('');
        break;
      case 'start-stream':
        if (msg.source === 'capture') startStream();
        break;
      case 'stop-stream':
        stopStream();
        break;
      case 'answer':
        if (pc && msg.answer) pc.setRemoteDescription(new RTCSessionDescription(msg.answer)).catch(console.error);
        break;
      case 'ice-candidate':
        if (pc && msg.candidate) pc.addIceCandidate(new RTCIceCandidate(msg.candidate)).catch(console.error);
        break;
      case 'disconnected':
        showError(msg.message || 'Session ended.');
        ready = false;
        stopStream();
        els.connectBtn.disabled = false;
        break;
      case 'error':
        showError(msg.message);
        els.connectBtn.disabled = false;
        break;
    }
  }

  async function joinSession() {
    const params = new URLSearchParams(location.search);
    const code = (params.get('code') || els.codeInput.value).replace(/\D/g, '').slice(0, 6);
    if (code.length !== 6) {
      showError('Enter the same 6-digit code shown on your glasses.');
      return;
    }

    showError('');
    els.connectBtn.disabled = true;
    setStatus('waiting', 'Joining…');

    try {
      await CasterSignaling.wakeServer();
      ws?.close();
      ws = CasterSignaling.createSignalingConnection(handleMessage, () => {
        if (ready) setStatus('error', 'Reconnecting…');
      });
      await CasterSignaling.waitForOpen(ws);
      CasterSignaling.send(ws, { type: 'register-capture', code });
      await CasterSignaling.waitForMessage(ws, 'registered');
    } catch (err) {
      console.error('[caster] capture join failed:', err);
      showError(err.message || 'Could not join. Check the code and try again.');
      els.connectBtn.disabled = false;
      setStatus('waiting', 'Enter code from glasses');
      ws?.close();
      ws = null;
    }
  }

  els.connectBtn.addEventListener('click', joinSession);
  els.codeInput.addEventListener('keydown', (e) => { if (e.key === 'Enter') joinSession(); });
  els.codeInput.addEventListener('input', () => {
    els.codeInput.value = els.codeInput.value.replace(/\D/g, '').slice(0, 6);
  });

  const preset = new URLSearchParams(location.search).get('code');
  if (preset) {
    els.codeInput.value = preset.replace(/\D/g, '').slice(0, 6);
    joinSession();
  } else {
    setStatus('waiting', 'Enter code from glasses');
  }
})();
