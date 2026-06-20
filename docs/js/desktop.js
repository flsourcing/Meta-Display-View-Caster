/**
 * Desktop viewer — WebSocket signaling (native phone app) or PeerJS fallback.
 */
(function () {
  const useWS = !!(window.CASTER_CONFIG?.SIGNALING_URL || window.CASTER_CONFIG?.SIGNALING_HOST);

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
    setViewerStatus('connected', useWS ? 'Connected — connect glasses' : 'Connected to phone relay — connect glasses');
    if (useWS) {
      els.captureHint.textContent = 'Camera runs in the phone app. Tap Live Stream on glasses.';
    } else {
      els.captureHint.textContent = 'Camera runs on your phone. Tap Live Stream on glasses to start.';
    }
  }

  function cleanupCall() {
    activeCall?.close();
    activeCall = null;
    pc?.close();
    pc = null;
    els.remoteVideo.srcObject = null;
    els.videoPlaceholder.classList.remove('hidden');
  }

  function destroyPeers() {
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
    ws?.close();
    ws = null;
    dataConn?.close();
    dataConn = null;
    destroyPeers();
    els.viewerSection.classList.add('hidden');
    els.connectSection.classList.remove('hidden');
    els.connectBtn.disabled = false;
    els.connectBtn.textContent = 'Connect';
    setStatus('waiting', useWS ? 'Enter code from phone app' : 'Enter code from phone relay');
    showError('');
  }

  function bindWsMessages() {
    ws.addEventListener('message', async (ev) => {
      let msg;
      try { msg = JSON.parse(ev.data); } catch { return; }
      if (msg.type === 'offer' && !pc) {
        pc = CasterWebRTCViewer.createPeerConnection((stream) => {
          els.remoteVideo.srcObject = stream;
          els.videoPlaceholder.classList.add('hidden');
          setViewerStatus('connected', 'Live stream active');
        });
        CasterWebRTCViewer.bindIce(pc, ws);
        await CasterWebRTCViewer.handleOffer(pc, ws, msg);
      }
      if (msg.type === 'ice-candidate' && pc) await CasterWebRTCViewer.handleRemoteIce(pc, msg);
      if (msg.type === 'stream-started') setViewerStatus('connected', 'Stream starting…');
      if (msg.type === 'stop-stream') {
        cleanupCall();
        setViewerStatus('connected', 'Connected — tap Live Stream on glasses');
      }
      if (msg.type === 'disconnected') resetToConnect();
    });
    ws.addEventListener('close', () => { if (connected) resetToConnect(); });
  }

  async function connectWS(code) {
    setStatus('waiting', 'Waking signaling server…');
    await CasterWS.wakeServer?.().catch(() => {});
    setStatus('waiting', 'Connecting…');
    ws = await CasterWS.pairDesktop(code);
    bindWsMessages();
    connected = true;
    showViewer(code);
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

  async function connectPeerJS(code) {
    destroyPeers();
    connectAbort = false;
    clientPeer = await CasterSignaling.createPeerWithRetry();
    setupPeer(clientPeer);
    const onStatus = (msg) => { if (!connectAbort) setStatus('waiting', msg); };
    const conn = await CasterSignaling.withTimeout(
      CasterSignaling.connectToRelay(code, clientPeer, 'desktop', onStatus),
      55000,
      'Timed out. Keep the phone app open with a green dot, then try again.',
    );
    if (connectAbort) throw new Error('Cancelled.');
    peer = clientPeer;
    return conn;
  }

  function bindPeerRelayMessages() {
    dataConn.on('data', (msg) => {
      if (msg?.type === 'stream-started') setViewerStatus('connected', 'Stream starting…');
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
      showError(useWS ? 'Enter the 6-digit code from the phone app.' : 'Enter the 6-digit code from the View Caster app on your phone.');
      return;
    }

    connecting = true;
    els.connectBtn.textContent = 'Cancel';
    showError('');
    setStatus('waiting', 'Connecting…');

    try {
      if (useWS) {
        await connectWS(code);
      } else {
        dataConn = await connectPeerJS(code);
        bindPeerRelayMessages();
        connected = true;
        showViewer(code);
      }
      els.connectBtn.disabled = true;
      els.connectBtn.textContent = 'Connect';
    } catch (err) {
      console.error(err);
      destroyPeers();
      ws?.close();
      ws = null;
      let msg = err.message || 'Connection failed.';
      if (useWS && msg.includes('not found')) msg += ' Keep the phone app open until you see a code.';
      if (useWS && (msg.includes('Could not reach') || msg.includes('timeout') || msg.includes('not configured'))) {
        msg += ' Deploy the signaling server: deploy-server.html';
      }
      showError(msg);
      setStatus('error', 'Could not connect');
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
      destroyPeers();
      ws?.close();
      ws = null;
      els.connectBtn.textContent = 'Connect';
      els.connectBtn.disabled = false;
      setStatus('waiting', useWS ? 'Enter code from phone app' : 'Enter code from phone relay');
      showError('Cancelled.');
      return;
    }
    connect();
  });
  els.codeInput.addEventListener('keydown', (e) => { if (e.key === 'Enter' && !connecting) connect(); });
  els.codeInput.addEventListener('input', () => {
    els.codeInput.value = els.codeInput.value.replace(/\D/g, '').slice(0, 6);
  });

  setStatus('waiting', useWS ? 'Enter code from phone app' : 'Enter code from phone relay');
  if (!useWS) CasterSignaling.createPeerWithRetry().then((p) => { clientPeer = p; setupPeer(p); }).catch(() => {});

  if (urlCode?.length === 6) setTimeout(connect, 300);
})();
