/**
 * Desktop viewer — enter pairing code, connect, receive live stream
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
    streamBtn: document.getElementById('stream-btn'),
    remoteVideo: document.getElementById('remote-video'),
    videoPlaceholder: document.getElementById('video-placeholder'),
  };

  let ws = null;
  let pc = null;
  let streaming = false;
  let connected = false;

  function setStatus(kind, text) {
    els.status.className = `status ${kind}`;
    els.statusText.textContent = text;
  }

  function showError(msg) {
    els.errorMsg.textContent = msg || '';
    els.errorMsg.classList.toggle('error', !!msg);
  }

  function showViewer() {
    els.connectSection.classList.add('hidden');
    els.viewerSection.classList.remove('hidden');
    setStatus('connected', 'Connected to glasses');
  }

  function resetToConnect() {
    connected = false;
    streaming = false;
    pc?.close();
    pc = null;
    els.remoteVideo.srcObject = null;
    els.viewerSection.classList.add('hidden');
    els.connectSection.classList.remove('hidden');
    els.streamBtn.textContent = 'Live Stream';
    els.streamBtn.classList.remove('active');
    els.streamBtn.disabled = false;
    els.videoPlaceholder.classList.remove('hidden');
    setStatus('waiting', 'Waiting to connect');
    showError('');
  }

  function ensurePeerConnection() {
    if (pc) return pc;

    pc = CasterSignaling.createPeerConnection(
      (event) => {
        if (event.streams?.[0]) {
          els.remoteVideo.srcObject = event.streams[0];
          els.videoPlaceholder.classList.add('hidden');
        }
      },
      (candidate) => {
        CasterSignaling.send(ws, { type: 'ice-candidate', candidate });
      }
    );

    return pc;
  }

  async function handleOffer(offer) {
    const peer = ensurePeerConnection();
    await peer.setRemoteDescription(new RTCSessionDescription(offer));
    const answer = await peer.createAnswer();
    await peer.setLocalDescription(answer);
    CasterSignaling.send(ws, { type: 'answer', answer: peer.localDescription });
  }

  function handleMessage(msg) {
    switch (msg.type) {
      case 'paired':
        connected = true;
        showViewer();
        showError('');
        break;

      case 'error':
        showError(msg.message);
        els.connectBtn.disabled = false;
        break;

      case 'disconnected':
        showError(msg.message || 'Disconnected from glasses.');
        resetToConnect();
        break;

      case 'offer':
        handleOffer(msg.offer);
        break;

      case 'ice-candidate':
        if (msg.candidate && pc) {
          pc.addIceCandidate(new RTCIceCandidate(msg.candidate)).catch(console.error);
        }
        break;

      case 'stop-stream':
        streaming = false;
        els.streamBtn.textContent = 'Live Stream';
        els.streamBtn.classList.remove('active');
        els.remoteVideo.srcObject = null;
        els.videoPlaceholder.classList.remove('hidden');
        break;
    }
  }

  function connect() {
    const code = els.codeInput.value.replace(/\D/g, '').slice(0, 6);
    if (code.length !== 6) {
      showError('Enter the 6-digit code shown on your glasses.');
      return;
    }

    showError('');
    els.connectBtn.disabled = true;
    setStatus('waiting', 'Connecting…');

    try {
      ws = CasterSignaling.createSignalingConnection(handleMessage, () => {
        if (connected) {
          showError('Lost connection to server.');
          resetToConnect();
        }
      });

      ws.addEventListener('open', () => {
        CasterSignaling.send(ws, { type: 'pair', code });
      });
    } catch (err) {
      showError(err.message);
      els.connectBtn.disabled = false;
      setStatus('error', 'Configuration error');
    }
  }

  function toggleStream() {
    if (!connected || !ws) return;

    if (!streaming) {
      streaming = true;
      els.streamBtn.textContent = 'Stop Stream';
      els.streamBtn.classList.add('active');
      CasterSignaling.send(ws, { type: 'start-stream' });
    } else {
      streaming = false;
      els.streamBtn.textContent = 'Live Stream';
      els.streamBtn.classList.remove('active');
      CasterSignaling.send(ws, { type: 'stop-stream' });
      els.remoteVideo.srcObject = null;
      els.videoPlaceholder.classList.remove('hidden');
      pc?.close();
      pc = null;
    }
  }

  els.connectBtn.addEventListener('click', connect);
  els.codeInput.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') connect();
  });
  els.codeInput.addEventListener('input', () => {
    els.codeInput.value = els.codeInput.value.replace(/\D/g, '').slice(0, 6);
  });
  els.streamBtn.addEventListener('click', toggleStream);

  setStatus('waiting', 'Enter code from glasses');
})();
