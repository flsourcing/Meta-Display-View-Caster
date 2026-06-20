/**
 * Desktop viewer — races phone→desktop and desktop→phone in parallel.
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
  let connectAbort = false;
  let hostPeer = null;
  let clientPeer = null;

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

  function destroyConnectPeers() {
    hostPeer?.destroy();
    clientPeer?.destroy();
    hostPeer = null;
    clientPeer = null;
    peer = null;
  }

  function resetToConnect() {
    connected = false;
    connecting = false;
    connectAbort = true;
    cleanupCall();
    dataConn?.close();
    dataConn = null;
    destroyConnectPeers();
    els.viewerSection.classList.add('hidden');
    els.connectSection.classList.remove('hidden');
    els.connectBtn.disabled = false;
    els.connectBtn.textContent = 'Connect';
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

  function abortIfCancelled() {
    if (connectAbort) throw new Error('Cancelled');
  }

  async function raceConnect(code) {
    destroyConnectPeers();
    connectAbort = false;

    hostPeer = CasterSignaling.createPeer(CasterSignaling.desktopPeerIdForCode(code));
    clientPeer = await CasterSignaling.createPeerWithRetry();
    setupPeer(hostPeer);
    setupPeer(clientPeer);

    const onStatus = (msg) => {
      if (!connectAbort) setStatus('waiting', msg);
    };

    const inbound = (async () => {
      abortIfCancelled();
      await CasterSignaling.waitForPeerOpen(hostPeer, 12000);
      abortIfCancelled();
      onStatus('Waiting for phone…');
      const conn = await CasterSignaling.waitForIncomingHello(hostPeer, 'phone-relay', 20000);
      return { conn, keep: hostPeer, drop: clientPeer };
    })();

    const outbound = (async () => {
      abortIfCancelled();
      onStatus('Finding phone relay…');
      const conn = await CasterSignaling.connectToRelay(code, clientPeer, 'desktop', onStatus);
      return { conn, keep: clientPeer, drop: hostPeer };
    })();

    const result = await CasterSignaling.withTimeout(
      Promise.race([inbound, outbound]),
      25000,
      'Timed out. On phone: refresh relay.html, wait for green dot, enter the new code here.',
    );

    abortIfCancelled();
    result.drop?.destroy();
    peer = result.keep;
    return result.conn;
  }

  async function connect() {
    if (connecting) return;
    const code = els.codeInput.value.replace(/\D/g, '').slice(0, 6);
    if (code.length !== 6) {
      showError('Enter the 6-digit code from relay.html on your phone.');
      return;
    }

    connecting = true;
    els.connectBtn.disabled = false;
    els.connectBtn.textContent = 'Cancel';
    showError('');
    setStatus('waiting', 'Connecting…');

    try {
      dataConn = await raceConnect(code);
      bindRelayMessages();
      connected = true;
      els.connectBtn.textContent = 'Connect';
      els.connectBtn.disabled = true;
      showViewer(code);
    } catch (err) {
      console.error(err);
      destroyConnectPeers();
      if (err.message !== 'Cancelled') {
        showError(err.message || 'Connection failed.');
        setStatus('error', 'Could not connect');
      }
      els.connectBtn.textContent = 'Connect';
      els.connectBtn.disabled = false;
    } finally {
      connecting = false;
    }
  }

  els.connectBtn.addEventListener('click', () => {
    if (connecting) {
      connectAbort = true;
      connecting = false;
      destroyConnectPeers();
      els.connectBtn.textContent = 'Connect';
      els.connectBtn.disabled = false;
      setStatus('waiting', 'Enter code from phone relay');
      showError('Cancelled.');
      return;
    }
    connect();
  });
  els.codeInput.addEventListener('keydown', (e) => { if (e.key === 'Enter' && !connecting) connect(); });
  els.codeInput.addEventListener('input', () => {
    els.codeInput.value = els.codeInput.value.replace(/\D/g, '').slice(0, 6);
  });

  setStatus('waiting', 'Enter code from phone relay');

  if (urlCode?.length === 6) setTimeout(connect, 300);
})();
