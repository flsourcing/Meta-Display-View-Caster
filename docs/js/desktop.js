/**
 * Desktop viewer — enter code, connect, receive live stream
 */

(function () {
  const els = {
    connectSection: document.getElementById('connect-section'),
    viewerSection: document.getElementById('viewer-section'),
    codeInput: document.getElementById('code-input'),
    connectBtn: document.getElementById('connect-btn'),
    status: document.getElementById('status'),
    statusText: document.getElementById('status-text'),
    errorMsg: document.getElementById('error-msg'),
    remoteVideo: document.getElementById('remote-video'),
    videoPlaceholder: document.getElementById('video-placeholder'),
    statusViewer: document.getElementById('status-viewer'),
    captureHint: document.getElementById('capture-hint'),
  };

  let ws = null;
  let pc = null;
  let connected = false;
  let connecting = false;

  function setStatus(kind, text) {
    els.status.className = `status ${kind}`;
    els.statusText.textContent = text;
  }

  function setViewerStatus(kind, text) {
    els.statusViewer.className = `status ${kind}`;
    els.statusViewer.querySelector('span:last-child').textContent = text;
  }

  function showError(msg) {
    els.errorMsg.textContent = msg || '';
    els.errorMsg.classList.toggle('error', !!msg);
  }

  function showViewer(code) {
    els.connectSection.classList.add('hidden');
    els.viewerSection.classList.remove('hidden');
    setStatus('connected', 'Connected to glasses');
    setViewerStatus('connected', 'Connected — open capture.html on phone, tap Live Stream on glasses');
    els.captureHint.innerHTML = `Open <a href="capture.html?code=${code}">capture.html</a> on your phone with code <strong>${code}</strong>, then tap Live Stream on glasses.`;
  }

  function cleanupCall() {
    pc?.close();
    pc = null;
    els.remoteVideo.srcObject = null;
    els.videoPlaceholder.classList.remove('hidden');
    if (connected) setViewerStatus('connected', 'Connected — tap Live Stream on glasses');
  }

  function resetToConnect() {
    connected = false;
    connecting = false;
    cleanupCall();
    ws?.close();
    ws = null;
    els.viewerSection.classList.add('hidden');
    els.connectSection.classList.remove('hidden');
    els.connectBtn.disabled = false;
    setStatus('waiting', 'Enter code from glasses');
    showError('');
  }

  function ensurePc() {
    if (pc) return pc;
    pc = CasterSignaling.createPeerConnection(
      (e) => {
        if (e.streams?.[0]) {
          els.remoteVideo.srcObject = e.streams[0];
          els.videoPlaceholder.classList.add('hidden');
          setViewerStatus('connected', 'Live stream active');
        }
      },
      (c) => CasterSignaling.send(ws, { type: 'ice-candidate', candidate: c }),
    );
    return pc;
  }

  function handleMessage(msg) {
    switch (msg.type) {
      case 'paired':
        connected = true;
        connecting = false;
        showViewer(msg.code || els.codeInput.value);
        showError('');
        break;
      case 'error':
        if (connecting) throw new Error(msg.message);
        showError(msg.message);
        break;
      case 'disconnected':
        showError(msg.message || 'Disconnected.');
        resetToConnect();
        break;
      case 'offer':
        handleOffer(msg.offer);
        break;
      case 'stream-started':
        setViewerStatus('connected', 'Receiving live stream…');
        break;
      case 'stop-stream':
        cleanupCall();
        break;
      case 'ice-candidate':
        if (pc && msg.candidate) pc.addIceCandidate(new RTCIceCandidate(msg.candidate)).catch(console.error);
        break;
    }
  }

  async function handleOffer(offer) {
    const peer = ensurePc();
    await peer.setRemoteDescription(new RTCSessionDescription(offer));
    const answer = await peer.createAnswer();
    await peer.setLocalDescription(answer);
    CasterSignaling.send(ws, { type: 'answer', answer: peer.localDescription });
  }

  async function connect() {
    if (connecting) return;
    const code = els.codeInput.value.replace(/\D/g, '').slice(0, 6);
    if (code.length !== 6) {
      showError('Enter the 6-digit code shown on your glasses.');
      return;
    }

    showError('');
    connecting = true;
    els.connectBtn.disabled = true;
    setStatus('waiting', 'Waking server…');

    try {
      await CasterSignaling.wakeServer();
      setStatus('waiting', 'Connecting…');

      ws = CasterSignaling.createSignalingConnection(handleMessage, () => {
        if (connected) resetToConnect();
      });

      await CasterSignaling.waitForOpen(ws);
      CasterSignaling.send(ws, { type: 'pair', code });

      const paired = await CasterSignaling.waitForMessage(ws, 'paired');
      connected = true;
      connecting = false;
      showViewer(paired.code || code);
      showError('');
    } catch (err) {
      console.error('[caster] connect failed:', err);
      connecting = false;
      const msg = err.message?.includes('Failed to fetch') || err.message?.includes('NetworkError')
        ? 'Signaling server not reachable. Deploy it on Render (see GitHub README), wait 1 minute, then try again.'
        : (err.message || 'Could not connect. Wait for "Ready" on glasses, then enter the current code.');
      showError(msg);
      els.connectBtn.disabled = false;
      setStatus('waiting', 'Enter code from glasses');
      ws?.close();
      ws = null;
    }
  }

  els.connectBtn.addEventListener('click', connect);
  els.codeInput.addEventListener('keydown', (e) => { if (e.key === 'Enter') connect(); });
  els.codeInput.addEventListener('input', () => {
    els.codeInput.value = els.codeInput.value.replace(/\D/g, '').slice(0, 6);
  });

  setStatus('waiting', 'Enter code from glasses');
})();
