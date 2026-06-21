/**
 * Public viewer — password "Wedding", auto-connect, works on phone browsers.
 */
(function () {
  const useWS = !!(window.CASTER_CONFIG?.SIGNALING_URL || window.CASTER_CONFIG?.SIGNALING_HOST);
  const defaultPassword = window.CASTER_CONFIG?.VIEWER_PASSWORD || 'Wedding';

  const els = {
    connectSection: document.getElementById('connect-section'),
    viewerSection: document.getElementById('viewer-section'),
    passwordInput: document.getElementById('password-input'),
    connectBtn: document.getElementById('connect-btn'),
    status: document.getElementById('status'),
    statusText: document.getElementById('status-text'),
    errorMsg: document.getElementById('error-msg'),
    remoteVideo: document.getElementById('remote-video'),
    videoPlaceholder: document.getElementById('video-placeholder'),
    statusViewer: document.getElementById('status-viewer'),
    captureHint: document.getElementById('capture-hint'),
    unmuteBtn: document.getElementById('unmute-btn'),
  };

  let ws = null;
  let pc = null;
  let viewerId = null;
  let connected = false;
  let connecting = false;
  let retryTimer = null;
  let autoStarted = false;

  const params = new URLSearchParams(location.search);
  const urlPassword = params.get('password') || params.get('p') || defaultPassword;
  if (els.passwordInput) els.passwordInput.value = urlPassword;

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

  function showViewer() {
    els.connectSection.classList.add('hidden');
    els.viewerSection.classList.remove('hidden');
    setViewerStatus('waiting', 'Connected — waiting for live stream…');
    els.captureHint.textContent = 'Stream appears automatically when Live Stream starts on glasses.';
  }

  function cleanupCall() {
    pc?.close();
    pc = null;
    els.remoteVideo.srcObject = null;
    els.videoPlaceholder.classList.remove('hidden');
  }

  function resetConnection() {
    connected = false;
    connecting = false;
    cleanupCall();
    ws?.close();
    ws = null;
    viewerId = null;
    els.viewerSection.classList.add('hidden');
    els.connectSection.classList.remove('hidden');
    els.connectBtn.disabled = false;
    els.connectBtn.textContent = 'Watch live';
  }

  function scheduleRetry() {
    if (retryTimer) return;
    retryTimer = window.setTimeout(() => {
      retryTimer = null;
      if (!connected && !connecting) connect();
    }, 5000);
  }

  function bindWsMessages() {
    ws.addEventListener('message', async (ev) => {
      let msg;
      try { msg = JSON.parse(ev.data); } catch { return; }

      if (msg.type === 'offer') {
        if (!pc) {
          pc = CasterWebRTCViewer.createPeerConnection((stream) => {
            els.remoteVideo.srcObject = stream;
            els.videoPlaceholder.classList.add('hidden');
            setViewerStatus('connected', 'Live stream active');
          });
          CasterWebRTCViewer.bindIce(pc, ws, viewerId);
        }
        await CasterWebRTCViewer.handleOffer(pc, ws, msg, viewerId);
      }

      if (msg.type === 'ice-candidate' && pc) {
        await CasterWebRTCViewer.handleRemoteIce(pc, msg);
      }

      if (msg.type === 'stream-started') {
        setViewerStatus('waiting', 'Stream starting…');
      }

      if (msg.type === 'stream-starting') {
        setViewerStatus('waiting', 'Glasses camera starting…');
      }

      if (msg.type === 'stop-stream') {
        cleanupCall();
        setViewerStatus('waiting', 'Stream ended — waiting for next Live Stream…');
      }

      if (msg.type === 'relay-offline') {
        cleanupCall();
        setViewerStatus('error', 'Phone relay offline');
        resetConnection();
        setStatus('waiting', 'Waiting for cast…');
        scheduleRetry();
      }
    });

    ws.addEventListener('close', () => {
      if (connected) {
        resetConnection();
        setStatus('waiting', 'Reconnecting…');
        scheduleRetry();
      }
    });
  }

  async function connectWS(password) {
    setStatus('waiting', 'Waking signaling server…');
    await CasterWS.wakeServer?.().catch(() => {});
    setStatus('waiting', 'Joining live cast…');
    const joined = await CasterWS.joinViewer(password);
    ws = joined.ws;
    viewerId = joined.viewerId;
    bindWsMessages();
    connected = true;
    showViewer();
    if (joined.streaming) {
      setViewerStatus('waiting', 'Stream in progress — connecting video…');
    }
  }

  async function connect() {
    if (!useWS) {
      showError('WebSocket signaling required. Deploy the server (see deploy-server.html).');
      setStatus('error', 'Server not configured');
      return;
    }

    if (connecting) return;
    const password = (els.passwordInput?.value || defaultPassword).trim();
    if (!password) {
      showError('Enter the viewer password.');
      return;
    }

    connecting = true;
    els.connectBtn.textContent = 'Connecting…';
    showError('');

    try {
      await connectWS(password);
      els.connectBtn.disabled = true;
      els.connectBtn.textContent = 'Watching';
    } catch (err) {
      console.error(err);
      let msg = err.message || 'Connection failed.';
      if (msg.includes('No cast active')) {
        msg = 'Waiting for cast — open View Caster on the phone, then start Live Stream.';
        setStatus('waiting', msg);
      } else {
        setStatus('error', 'Could not connect');
      }
      showError(msg);
      els.connectBtn.textContent = 'Watch live';
      els.connectBtn.disabled = false;
      scheduleRetry();
    } finally {
      connecting = false;
    }
  }

  els.connectBtn?.addEventListener('click', connect);
  els.passwordInput?.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !connecting) connect();
  });

  els.unmuteBtn?.addEventListener('click', () => {
    els.remoteVideo.muted = false;
    els.unmuteBtn.textContent = 'Sound on';
    els.unmuteBtn.disabled = true;
  });

  async function autoConnectLoop() {
    if (connected || connecting || !useWS) return;
    try {
      const live = await CasterWS.fetchLiveStatus();
      if (live.relayOnline) {
        await connect();
        return;
      }
    } catch { /* ignore */ }
    setStatus('waiting', 'Waiting for live cast — open View Caster on phone…');
    scheduleRetry();
  }

  setStatus('waiting', 'Connecting automatically…');
  if (useWS) {
    window.setTimeout(() => {
      if (!autoStarted) {
        autoStarted = true;
        autoConnectLoop();
      }
    }, 400);
  } else {
    setStatus('error', 'Signaling server not configured');
  }
})();
