/**
 * Desktop viewer — connects to phone relay.
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

  let peer = null;
  let dataConn = null;
  let activeCall = null;
  let connected = false;
  let connecting = false;
  let peerReady = null;

  const params = new URLSearchParams(location.search);
  const urlCode = params.get('code')?.replace(/\D/g, '').slice(0, 6);
  if (urlCode && els.codeInput) els.codeInput.value = urlCode;

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
    setViewerStatus('connected', 'Connected to phone relay — connect glasses');
    els.captureHint.innerHTML = `When streaming: open <a href="capture.html?code=${code}" target="_blank" rel="noopener">capture.html?code=${code}</a> on your phone and allow camera.`;
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
    cleanupCall();
    dataConn?.close();
    dataConn = null;
    els.viewerSection.classList.add('hidden');
    els.connectSection.classList.remove('hidden');
    els.connectBtn.disabled = false;
    setStatus('waiting', 'Enter code from phone relay');
    showError('');
  }

  function setupPeer(p) {
    p.on('call', (call) => {
      activeCall = call;
      call.answer();
      call.on('stream', (s) => {
        els.remoteVideo.srcObject = s;
        els.videoPlaceholder.classList.add('hidden');
        setViewerStatus('connected', 'Live stream active');
      });
      call.on('close', cleanupCall);
    });
  }

  async function ensurePeer() {
    if (peer?.open) return peer;
    peer?.destroy();
    peer = await CasterSignaling.createPeerWithRetry();
    setupPeer(peer);
    return peer;
  }

  function bindRelayMessages() {
    dataConn.on('data', (msg) => {
      if (msg?.type === 'stream-started') {
        setViewerStatus('connected', 'Stream starting…');
      }
      if (msg?.type === 'stop-stream') {
        cleanupCall();
        setViewerStatus('connected', 'Connected — tap Live Stream on glasses');
      }
    });
    dataConn.on('close', () => { if (connected) resetToConnect(); });
  }

  async function connect() {
    if (connecting) return;
    const code = els.codeInput.value.replace(/\D/g, '').slice(0, 6);
    if (code.length !== 6) {
      showError('Enter the 6-digit code from relay.html on your phone.');
      return;
    }

    connecting = true;
    els.connectBtn.disabled = true;
    showError('');
    setStatus('waiting', 'Connecting…');

    try {
      const p = await ensurePeer();
      dataConn = await CasterSignaling.connectToRelay(code, p, 'desktop');
      bindRelayMessages();
      connected = true;
      showViewer(code);
    } catch (err) {
      console.error(err);
      showError(`${err.message || 'Connection failed.'} Keep relay.html open on your phone and try again.`);
      setStatus('waiting', 'Enter code from phone relay');
      els.connectBtn.disabled = false;
    } finally {
      connecting = false;
    }
  }

  els.connectBtn.addEventListener('click', connect);
  els.codeInput.addEventListener('keydown', (e) => { if (e.key === 'Enter') connect(); });
  els.codeInput.addEventListener('input', () => {
    els.codeInput.value = els.codeInput.value.replace(/\D/g, '').slice(0, 6);
  });

  setStatus('waiting', 'Enter code from phone relay');
  peerReady = ensurePeer().catch(() => {});

  if (urlCode?.length === 6) {
    peerReady.finally(() => connect());
  }
})();
