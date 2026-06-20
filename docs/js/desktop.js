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

  let peer = null;
  let dataConn = null;
  let activeCall = null;
  let streaming = false;
  let connected = false;
  let connecting = false;

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

  function cleanupCall() {
    activeCall?.close();
    activeCall = null;
    els.remoteVideo.srcObject = null;
    els.videoPlaceholder.classList.remove('hidden');
  }

  function resetToConnect() {
    connected = false;
    connecting = false;
    streaming = false;
    cleanupCall();
    dataConn?.close();
    dataConn = null;
    peer?.destroy();
    peer = null;
    els.viewerSection.classList.add('hidden');
    els.connectSection.classList.remove('hidden');
    els.streamBtn.textContent = 'Live Stream';
    els.streamBtn.classList.remove('active');
    els.streamBtn.disabled = false;
    els.connectBtn.disabled = false;
    setStatus('waiting', 'Enter code from glasses');
    showError('');
  }

  function setupPeerHandlers() {
    peer.on('call', (call) => {
      activeCall = call;
      call.answer();
      call.on('stream', (stream) => {
        els.remoteVideo.srcObject = stream;
        els.videoPlaceholder.classList.add('hidden');
      });
      call.on('close', () => {
        if (streaming) cleanupCall();
      });
    });

    peer.on('disconnected', () => {
      if (connected) showError('Connection lost. Try reconnecting.');
    });

    peer.on('close', () => {
      if (connected) resetToConnect();
    });
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
    setStatus('waiting', 'Joining network…');

    const glassesPeerId = CasterSignaling.peerIdForCode(code);

    try {
      peer = CasterSignaling.createPeer();
      setupPeerHandlers();

      await CasterSignaling.waitForPeerOpen(peer);
      setStatus('waiting', 'Finding glasses…');

      dataConn = peer.connect(glassesPeerId, { reliable: true });
      await CasterSignaling.waitForConnection(dataConn);

      dataConn.on('data', (msg) => {
        if (msg?.type === 'stop-stream') {
          streaming = false;
          els.streamBtn.textContent = 'Live Stream';
          els.streamBtn.classList.remove('active');
          cleanupCall();
        }
      });

      dataConn.on('close', () => {
        if (connected) {
          showError('Glasses disconnected.');
          resetToConnect();
        }
      });

      CasterSignaling.sendData(dataConn, { type: 'hello', peerId: peer.id });
      connected = true;
      connecting = false;
      showViewer();
      showError('');
    } catch (err) {
      console.error('[caster] connect failed:', err);
      connecting = false;
      showError(err.message || 'Could not connect. Use the current code from glasses.html and try again.');
      els.connectBtn.disabled = false;
      setStatus('waiting', 'Enter code from glasses');
      peer?.destroy();
      peer = null;
      dataConn = null;
    }
  }

  function toggleStream() {
    if (!connected || !dataConn?.open) return;

    if (!streaming) {
      streaming = true;
      els.streamBtn.textContent = 'Stop Stream';
      els.streamBtn.classList.add('active');
      CasterSignaling.sendData(dataConn, { type: 'start-stream', peerId: peer.id });
    } else {
      streaming = false;
      els.streamBtn.textContent = 'Live Stream';
      els.streamBtn.classList.remove('active');
      CasterSignaling.sendData(dataConn, { type: 'stop-stream' });
      cleanupCall();
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
