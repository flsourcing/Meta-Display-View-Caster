/**
 * Public viewer — password, then username, cast window + live chat.
 */
(function () {
  const useWS = !!(window.CASTER_CONFIG?.SIGNALING_URL || window.CASTER_CONFIG?.SIGNALING_HOST);
  const defaultPassword = window.CASTER_CONFIG?.VIEWER_PASSWORD || 'Wedding';

  const PLACEHOLDER = {
    noRelay: 'Waiting for caster — open View Caster on the phone',
    noStream: 'Waiting for Live Stream from glasses…',
    starting: 'Glasses camera starting…',
    live: '',
  };

  const els = {
    passwordSection: document.getElementById('password-section'),
    usernameSection: document.getElementById('username-section'),
    viewerSection: document.getElementById('viewer-section'),
    passwordInput: document.getElementById('password-input'),
    passwordBtn: document.getElementById('password-btn'),
    passwordError: document.getElementById('password-error'),
    usernameInput: document.getElementById('username-input'),
    joinBtn: document.getElementById('join-btn'),
    usernameError: document.getElementById('username-error'),
    usernameStatusText: document.getElementById('username-status-text'),
    status: document.getElementById('status'),
    statusText: document.getElementById('status-text'),
    remoteVideo: document.getElementById('remote-video'),
    videoWrap: document.getElementById('video-wrap'),
    videoPlaceholder: document.getElementById('video-placeholder'),
    statusViewer: document.getElementById('status-viewer'),
    captureHint: document.getElementById('capture-hint'),
    unmuteBtn: document.getElementById('unmute-btn'),
    fullscreenBtn: document.getElementById('fullscreen-btn'),
    viewerRoster: document.getElementById('viewer-roster'),
    chatMessages: document.getElementById('chat-messages'),
    chatForm: document.getElementById('chat-form'),
    chatInput: document.getElementById('chat-input'),
    chatSend: document.getElementById('chat-send'),
  };

  let ws = null;
  let pc = null;
  let viewerId = null;
  let viewerName = '';
  let verifiedPassword = '';
  let connected = false;
  let relayOnline = false;
  let passwordBusy = false;
  let joinBusy = false;
  const chatSeen = new Set();

  const params = new URLSearchParams(location.search);
  const urlPassword = params.get('password') || params.get('p') || '';
  const urlName = params.get('name') || params.get('username') || '';
  if (els.passwordInput && urlPassword) els.passwordInput.value = urlPassword;
  if (els.usernameInput && urlName) els.usernameInput.value = urlName.slice(0, 32);

  function passwordsMatch(a, b) {
    return String(a || '').trim().toLowerCase() === String(b || '').trim().toLowerCase();
  }

  function setStatus(kind, text) {
    els.status.className = `status ${kind}`;
    els.statusText.textContent = text;
  }

  function setViewerStatus(kind, text) {
    els.statusViewer.className = `status ${kind}`;
    els.statusViewer.querySelector('span:last-child').textContent = text;
  }

  function setVideoPlaceholder(text) {
    if (!els.videoPlaceholder) return;
    els.videoPlaceholder.textContent = text;
    if (text) els.videoPlaceholder.classList.remove('hidden');
  }

  function updateWaitingState() {
    if (els.remoteVideo?.srcObject) return;
    if (!relayOnline) {
      setVideoPlaceholder(PLACEHOLDER.noRelay);
      setViewerStatus('waiting', `Hi ${viewerName} — waiting for caster phone…`);
      if (els.captureHint) {
        els.captureHint.textContent = 'The cast window will show video automatically when Live Stream starts.';
      }
      return;
    }
    setVideoPlaceholder(PLACEHOLDER.noStream);
    setViewerStatus('waiting', `Hi ${viewerName} — caster connected, waiting for live stream…`);
    if (els.captureHint) {
      els.captureHint.textContent = 'Start Live Stream on the glasses when ready.';
    }
  }

  function showPasswordError(msg) {
    els.passwordError.textContent = msg || '';
    els.passwordError.classList.toggle('error', !!msg);
  }

  function showUsernameError(msg) {
    els.usernameError.textContent = msg || '';
    els.usernameError.classList.toggle('error', !!msg);
  }

  function renderViewerRoster(viewers) {
    if (!els.viewerRoster) return;
    els.viewerRoster.innerHTML = '';
    const list = Array.isArray(viewers) ? viewers : [];
    if (!list.length) {
      const li = document.createElement('li');
      li.className = 'viewer-roster-empty';
      li.textContent = 'No other viewers yet';
      els.viewerRoster.appendChild(li);
      return;
    }
    for (const viewer of list) {
      const li = document.createElement('li');
      li.className = 'viewer-roster-item';
      if (viewer.viewerId === viewerId) li.classList.add('is-self');
      const name = document.createElement('span');
      name.className = 'viewer-roster-name';
      name.textContent = viewer.name + (viewer.viewerId === viewerId ? ' (you)' : '');
      const badge = document.createElement('span');
      badge.className = `viewer-roster-badge ${viewer.status === 'watching' ? 'watching' : 'waiting'}`;
      badge.textContent = viewer.status === 'watching' ? 'Watching' : 'Waiting';
      li.append(name, badge);
      els.viewerRoster.appendChild(li);
    }
  }

  function scrollChatToBottom() {
    if (!els.chatMessages) return;
    els.chatMessages.scrollTop = els.chatMessages.scrollHeight;
  }

  function renderChatEmpty() {
    if (!els.chatMessages || els.chatMessages.children.length) return;
    const empty = document.createElement('p');
    empty.className = 'chat-empty';
    empty.textContent = 'No messages yet — say hi while you wait for the cast.';
    els.chatMessages.appendChild(empty);
  }

  function appendChatMessage(msg) {
    if (!els.chatMessages || !msg?.id || chatSeen.has(msg.id)) return;
    chatSeen.add(msg.id);

    const empty = els.chatMessages.querySelector('.chat-empty');
    if (empty) empty.remove();

    const item = document.createElement('div');
    item.className = 'chat-message';
    if (msg.viewerId === viewerId) item.classList.add('is-self');

    const name = document.createElement('span');
    name.className = 'chat-message-name';
    name.textContent = msg.name || 'Guest';

    const text = document.createElement('span');
    text.className = 'chat-message-text';
    text.textContent = msg.text || '';

    item.append(name, text);
    els.chatMessages.appendChild(item);
    scrollChatToBottom();
  }

  function loadChatHistory(history) {
    if (!els.chatMessages) return;
    els.chatMessages.innerHTML = '';
    chatSeen.clear();
    const list = Array.isArray(history) ? history : [];
    for (const msg of list) appendChatMessage(msg);
    renderChatEmpty();
    scrollChatToBottom();
  }

  function sendChatMessage(text) {
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    ws.send(JSON.stringify({ type: 'chat-message', text }));
  }

  function scrollToVideo() {
    requestAnimationFrame(() => {
      els.videoWrap?.scrollIntoView({ behavior: 'smooth', block: 'start' });
    });
  }

  function enterFullscreen() {
    const video = els.remoteVideo;
    if (!video) return;
    if (video.webkitEnterFullscreen) {
      video.webkitEnterFullscreen();
      return;
    }
    const target = els.videoWrap || video;
    if (target.requestFullscreen) {
      target.requestFullscreen().catch(() => {});
    } else if (video.requestFullscreen) {
      video.requestFullscreen().catch(() => {});
    }
  }

  function onStreamActive(stream) {
    els.remoteVideo.srcObject = stream;
    els.videoPlaceholder.classList.add('hidden');
    const hasAudio = stream.getAudioTracks().length > 0;
    if (hasAudio) {
      els.captureHint.textContent = 'Live stream includes audio — tap Tap for sound if needed.';
    } else {
      els.captureHint.textContent = '';
    }
    setViewerStatus('connected', `Live stream active — ${viewerName}`);
    scrollToVideo();
  }

  function showUsernameStep() {
    els.passwordSection.classList.add('hidden');
    els.usernameSection.classList.remove('hidden');
    els.usernameInput?.focus();
    if (els.usernameStatusText) {
      els.usernameStatusText.textContent = verifiedPassword
        ? 'Password accepted — enter your name to join'
        : 'Enter your name';
    }
  }

  function showViewerStep(options = {}) {
    relayOnline = !!options.relayOnline;
    els.passwordSection.classList.add('hidden');
    els.usernameSection.classList.add('hidden');
    els.viewerSection.classList.remove('hidden');
    document.body.classList.add('viewer-active');
    updateWaitingState();
    scrollToVideo();
    els.chatInput?.focus();
  }

  function cleanupCall() {
    pc?.close();
    pc = null;
    els.remoteVideo.srcObject = null;
    updateWaitingState();
  }

  function bindWsMessages() {
    ws.addEventListener('message', async (ev) => {
      let msg;
      try { msg = JSON.parse(ev.data); } catch { return; }

      if (msg.type === 'viewer-list-updated') {
        renderViewerRoster(msg.viewers);
      }

      if (msg.type === 'chat-message') {
        appendChatMessage(msg);
      }

      if (msg.type === 'relay-online') {
        relayOnline = true;
        updateWaitingState();
      }

      if (msg.type === 'glasses-joined') {
        if (relayOnline) updateWaitingState();
      }

      if (msg.type === 'offer') {
        if (!pc) {
          pc = CasterWebRTCViewer.createPeerConnection(onStreamActive);
          CasterWebRTCViewer.bindIce(pc, ws, viewerId);
        }
        await CasterWebRTCViewer.handleOffer(pc, ws, msg, viewerId);
      }

      if (msg.type === 'ice-candidate' && pc) {
        await CasterWebRTCViewer.handleRemoteIce(pc, msg);
      }

      if (msg.type === 'stream-started') {
        setVideoPlaceholder(PLACEHOLDER.starting);
        setViewerStatus('waiting', 'Stream starting…');
        scrollToVideo();
      }

      if (msg.type === 'stream-starting') {
        setVideoPlaceholder(PLACEHOLDER.starting);
        setViewerStatus('waiting', 'Glasses camera starting…');
        scrollToVideo();
      }

      if (msg.type === 'stop-stream') {
        cleanupCall();
        updateWaitingState();
      }

      if (msg.type === 'relay-offline') {
        relayOnline = false;
        cleanupCall();
        updateWaitingState();
      }
    });

    ws.addEventListener('close', () => {
      if (connected) {
        connected = false;
        cleanupCall();
        document.body.classList.remove('viewer-active');
        els.viewerSection.classList.add('hidden');
        els.usernameSection.classList.remove('hidden');
        showUsernameError('Connection lost — tap Join live stream to reconnect.');
      }
    });
  }

  async function verifyPassword() {
    if (!useWS || passwordBusy) return;
    const password = (els.passwordInput?.value || '').trim();
    if (!password) {
      showPasswordError('Enter the viewer password.');
      return;
    }

    if (!passwordsMatch(password, defaultPassword)) {
      showPasswordError('Wrong password.');
      setStatus('error', 'Wrong password');
      return;
    }

    passwordBusy = true;
    els.passwordBtn.disabled = true;
    els.passwordBtn.textContent = 'Checking…';
    showPasswordError('');
    setStatus('waiting', 'Checking cast status…');

    try {
      await CasterWS.wakeServer?.().catch(() => {});
      const live = await CasterWS.fetchLiveStatus().catch(() => ({ relayOnline: false, streaming: false }));
      verifiedPassword = password;
      showPasswordError('');
      if (!live.relayOnline) {
        setStatus('waiting', 'Password OK — join and wait for cast');
        if (els.usernameStatusText) {
          els.usernameStatusText.textContent = 'Password accepted. Join to open the cast window and chat while you wait.';
        }
      } else {
        setStatus('connected', live.streaming ? 'Password accepted — stream is live' : 'Password accepted');
      }
      showUsernameStep();
    } catch (err) {
      showPasswordError(err.message || 'Could not reach signaling server.');
      setStatus('error', 'Could not reach server');
    } finally {
      passwordBusy = false;
      els.passwordBtn.disabled = false;
      els.passwordBtn.textContent = 'Continue';
    }
  }

  async function joinWithUsername() {
    if (!useWS || joinBusy) return;
    const name = (els.usernameInput?.value || '').trim().replace(/\s+/g, ' ').slice(0, 32);
    if (!name) {
      showUsernameError('Enter your name so others can see who is watching.');
      return;
    }
    const password = verifiedPassword || (els.passwordInput?.value || '').trim();
    if (!password) {
      showUsernameError('Verify password first.');
      return;
    }

    joinBusy = true;
    els.joinBtn.disabled = true;
    els.joinBtn.textContent = 'Joining…';
    showUsernameError('');

    try {
      await CasterWS.wakeServer?.().catch(() => {});
      const joined = await CasterWS.joinViewer(password, name);
      ws = joined.ws;
      viewerId = joined.viewerId;
      viewerName = name;
      try { sessionStorage.setItem('mdvc-viewer-name', name); } catch { /* ignore */ }
      bindWsMessages();
      connected = true;
      renderViewerRoster(joined.viewers);
      loadChatHistory(joined.chatHistory);
      showViewerStep({
        relayOnline: joined.relayOnline,
        streaming: joined.streaming,
      });
      if (joined.streaming) {
        setVideoPlaceholder(PLACEHOLDER.noStream);
        setViewerStatus('waiting', 'Stream in progress — connecting video…');
        scrollToVideo();
      }
    } catch (err) {
      let msg = err.message || 'Could not join.';
      if (msg.includes('Unknown: join-viewer') || msg.includes('Unknown: chat-message')) {
        msg = 'Signaling server needs an update. Redeploy server/ on Render, then try again.';
      }
      showUsernameError(msg);
    } finally {
      joinBusy = false;
      els.joinBtn.disabled = false;
      els.joinBtn.textContent = 'Join live stream';
    }
  }

  els.passwordBtn?.addEventListener('click', verifyPassword);
  els.passwordInput?.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !passwordBusy) verifyPassword();
  });

  els.joinBtn?.addEventListener('click', joinWithUsername);
  els.usernameInput?.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !joinBusy) joinWithUsername();
  });

  els.unmuteBtn?.addEventListener('click', () => {
    els.remoteVideo.muted = false;
    els.unmuteBtn.textContent = 'Sound on';
    els.unmuteBtn.disabled = true;
  });

  els.fullscreenBtn?.addEventListener('click', enterFullscreen);
  els.remoteVideo?.addEventListener('click', () => {
    if (els.remoteVideo.srcObject) enterFullscreen();
  });

  els.chatForm?.addEventListener('submit', (e) => {
    e.preventDefault();
    const text = (els.chatInput?.value || '').trim();
    if (!text) return;
    sendChatMessage(text);
    els.chatInput.value = '';
    els.chatInput.focus();
  });

  try {
    const savedName = sessionStorage.getItem('mdvc-viewer-name');
    if (savedName && els.usernameInput && !els.usernameInput.value) {
      els.usernameInput.value = savedName;
    }
  } catch { /* ignore */ }

  setStatus('waiting', 'Enter password to continue');
})();
