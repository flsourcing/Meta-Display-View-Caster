/**
 * Desktop viewer — hosts the pairing session (stays online while tab is open).
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
  let glassesConn = null;
  let camConn = null;
  let activeCall = null;
  let sessionCode = '';
  let hosting = false;
  let glassesLinked = false;
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
    setViewerStatus('waiting', 'Session live — connect glasses with same code');
    els.captureHint.innerHTML = `Before streaming: open <a href="capture.html?code=${code}" target="_blank" rel="noopener">capture.html?code=${code}</a> on your phone.`;
  }

  function cleanupCall() {
    activeCall?.close();
    activeCall = null;
    els.remoteVideo.srcObject = null;
    els.videoPlaceholder.classList.remove('hidden');
  }

  function resetToConnect() {
    hosting = false;
    glassesLinked = false;
    connecting = false;
    cleanupCall();
    camConn?.close();
    camConn = null;
    glassesConn?.close();
    glassesConn = null;
    peer?.destroy();
    peer = null;
    sessionCode = '';
    els.viewerSection.classList.add('hidden');
    els.connectSection.classList.remove('hidden');
    els.connectBtn.disabled = false;
    setStatus('waiting', 'Enter code from phone relay');
    showError('');
  }

  function setupPeer() {
    peer.on('connection', (conn) => {
      conn.on('data', (msg) => {
        if (msg?.type === 'hello' && msg.role === 'glasses') {
          glassesConn = conn;
          glassesLinked = true;
          setViewerStatus('connected', 'Connected — tap Live Stream on glasses');
          CasterSignaling.sendData(conn, { type: 'relay-ack', role: 'glasses' });
        }
        if (msg?.type === 'start-stream') startCamBridge();
        if (msg?.type === 'stop-stream') stopCamBridge(true);
      });
      conn.on('close', () => {
        if (conn === glassesConn) {
          glassesConn = null;
          glassesLinked = false;
          if (hosting) {
            setViewerStatus('waiting', 'Glasses disconnected — reconnect with same code');
          }
        }
      });
    });

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

    peer.on('disconnected', () => {
      if (hosting) {
        try { peer.reconnect(); } catch { /* retry below */ }
      }
    });

    peer.on('close', () => {
      if (hosting && !peer.destroyed) {
        setTimeout(() => {
          if (hosting && sessionCode) connect(sessionCode, true);
        }, 2000);
      }
    });
  }

  async function startCamBridge() {
    if (!sessionCode) return;
    camConn?.close();
    camConn = peer.connect(CasterSignaling.camPeerIdForCode(sessionCode), { reliable: true });
    try {
      await CasterSignaling.waitForConnection(camConn, 15000);
      CasterSignaling.sendData(camConn, { type: 'start-stream', desktopPeerId: peer.id });
      CasterSignaling.sendData(glassesConn, { type: 'stream-started' });
    } catch {
      setViewerStatus('error', 'Open capture.html on your phone first');
      CasterSignaling.sendData(glassesConn, { type: 'stop-stream' });
    }
  }

  function stopCamBridge(notifyGlasses) {
    if (camConn?.open) {
      CasterSignaling.sendData(camConn, { type: 'stop-stream' });
    }
    camConn?.close();
    camConn = null;
    cleanupCall();
    if (notifyGlasses) CasterSignaling.sendData(glassesConn, { type: 'stop-stream' });
    if (glassesLinked) setViewerStatus('connected', 'Connected — tap Live Stream on glasses');
  }

  async function connect(codeOverride, isReconnect = false) {
    if (connecting) return;
    const code = (codeOverride || els.codeInput.value).replace(/\D/g, '').slice(0, 6);
    if (code.length !== 6) {
      showError('Enter the 6-digit code from relay.html on your phone.');
      return;
    }

    connecting = true;
    els.connectBtn.disabled = true;
    showError('');
    setStatus('waiting', isReconnect ? 'Reconnecting session…' : 'Starting session…');

    const maxAttempts = 5;
    let lastError;

    for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
      try {
        peer?.destroy();
        peer = CasterSignaling.createPeer(CasterSignaling.peerIdForCode(code));
        setupPeer();
        setStatus('waiting', `Registering session… (${attempt}/${maxAttempts})`);
        await CasterSignaling.waitForPeerOpen(peer, 45000);

        sessionCode = code;
        hosting = true;
        connecting = false;
        showViewer(code);
        setStatus('connected', 'Session live — now connect glasses');
        showError('');
        return;
      } catch (err) {
        lastError = err;
        console.warn(`host attempt ${attempt}`, err);
        if (attempt < maxAttempts) {
          setStatus('waiting', `Retrying… (${attempt + 1}/${maxAttempts})`);
          await new Promise((r) => setTimeout(r, 2000));
        }
      }
    }

    connecting = false;
    hosting = false;
    showError(
      lastError?.message
        ? `${lastError.message} Check internet and try again.`
        : 'Could not start session. Check internet and try again.',
    );
    els.connectBtn.disabled = false;
    setStatus('waiting', 'Enter code from phone relay');
    peer?.destroy();
    peer = null;
  }

  els.connectBtn.addEventListener('click', () => connect());
  els.codeInput.addEventListener('keydown', (e) => { if (e.key === 'Enter') connect(); });
  els.codeInput.addEventListener('input', () => {
    els.codeInput.value = els.codeInput.value.replace(/\D/g, '').slice(0, 6);
  });

  setStatus('waiting', 'Enter code from phone relay');

  if (urlCode?.length === 6) connect(urlCode);
})();
