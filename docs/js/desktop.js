/**
 * Desktop viewer
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
    setViewerStatus('connected', 'Connected — tap Live Stream on glasses');
    els.captureHint.innerHTML = `Phone camera: <a href="capture.html?code=${code}">capture.html?code=${code}</a>`;
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
    peer?.destroy();
    peer = null;
    els.viewerSection.classList.add('hidden');
    els.connectSection.classList.remove('hidden');
    els.connectBtn.disabled = false;
    setStatus('waiting', 'Enter code from phone relay');
    showError('');
  }

  function setupPeer() {
    peer.on('call', (call) => {
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

    const maxAttempts = 5;
    let lastError;

    for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
      try {
        peer?.destroy();
        peer = await CasterSignaling.createPeerWithRetry();
        setupPeer();
        setStatus('waiting', `Finding relay… (${attempt}/${maxAttempts})`);

        dataConn = peer.connect(CasterSignaling.peerIdForCode(code), { reliable: true });
        await CasterSignaling.waitForConnection(dataConn, 45000);

        dataConn.on('close', () => { if (connected) resetToConnect(); });
        CasterSignaling.sendData(dataConn, { type: 'hello', peerId: peer.id });
        connected = true;
        connecting = false;
        showViewer(code);
        showError('');
        return;
      } catch (err) {
        lastError = err;
        console.warn(`connect attempt ${attempt}`, err);
        if (attempt < maxAttempts) {
          setStatus('waiting', `Retrying… keep relay.html open on phone (${attempt + 1}/${maxAttempts})`);
          await new Promise((r) => setTimeout(r, 3000));
        }
      }
    }

    connecting = false;
    showError(
      lastError?.message
        ? `${lastError.message} Keep relay.html open on your phone (in foreground) and try again.`
        : 'Connection failed. Keep relay.html open on your phone and try again.',
    );
    els.connectBtn.disabled = false;
    setStatus('waiting', 'Enter code from phone relay');
    peer?.destroy();
    peer = null;
  }

  els.connectBtn.addEventListener('click', connect);
  els.codeInput.addEventListener('keydown', (e) => { if (e.key === 'Enter') connect(); });
  els.codeInput.addEventListener('input', () => {
    els.codeInput.value = els.codeInput.value.replace(/\D/g, '').slice(0, 6);
  });

  setStatus('waiting', 'Enter code from phone relay');

  if (urlCode?.length === 6) connect();
})();
