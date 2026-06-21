/**
 * Public viewer — password, then username, live roster.
 */
(function () {
  const useWS = !!(window.CASTER_CONFIG?.SIGNALING_URL || window.CASTER_CONFIG?.SIGNALING_HOST);
  const defaultPassword = window.CASTER_CONFIG?.VIEWER_PASSWORD || 'Wedding';

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
    videoPlaceholder: document.getElementById('video-placeholder'),
    statusViewer: document.getElementById('status-viewer'),
    captureHint: document.getElementById('capture-hint'),
    unmuteBtn: document.getElementById('unmute-btn'),
    viewerRoster: document.getElementById('viewer-roster'),
  };

  let ws = null;
  let pc = null;
  let viewerId = null;
  let viewerName = '';
  let verifiedPassword = '';
  let connected = false;
  let passwordBusy = false;
  let joinBusy = false;

  const params = new URLSearchParams(location.search);
  const urlPassword = params.get('password') || params.get('p') || defaultPassword;
  const urlName = params.get('name') || params.get('username') || '';
  if (els.passwordInput) els.passwordInput.value = urlPassword;
  if (els.usernameInput && urlName) els.usernameInput.value = urlName.slice(0, 32);

  function setStatus(kind, text) {
    els.status.className = `status ${kind}`;
    els.statusText.textContent = text;
  }

  function setViewerStatus(kind, text) {
    els.statusViewer.className = `status ${kind}`;
    els.statusViewer.querySelector('span:last-child').textContent = text;
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

  function showViewerStep() {
    els.passwordSection.classList.add('hidden');
    els.usernameSection.classList.add('hidden');
    els.viewerSection.classList.remove('hidden');
    setViewerStatus('waiting', `Hi ${viewerName} — waiting for live stream…`);
    els.captureHint.textContent = 'Stream appears automatically when Live Stream starts on glasses.';
  }

  function cleanupCall() {
    pc?.close();
    pc = null;
    els.remoteVideo.srcObject = null;
    els.videoPlaceholder.classList.remove('hidden');
  }

  function bindWsMessages() {
    ws.addEventListener('message', async (ev) => {
      let msg;
      try { msg = JSON.parse(ev.data); } catch { return; }

      if (msg.type === 'viewer-list-updated') {
        renderViewerRoster(msg.viewers);
      }

      if (msg.type === 'offer') {
        if (!pc) {
          pc = CasterWebRTCViewer.createPeerConnection((stream) => {
            els.remoteVideo.srcObject = stream;
            els.videoPlaceholder.classList.add('hidden');
            setViewerStatus('connected', `Live stream active — ${viewerName}`);
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
        connected = false;
        ws?.close();
        ws = null;
        els.viewerSection.classList.add('hidden');
        els.passwordSection.classList.remove('hidden');
        setStatus('waiting', 'Cast paused — try again when phone app reopens');
        showPasswordError('Phone relay went offline.');
      }
    });

    ws.addEventListener('close', () => {
      if (connected) {
        connected = false;
        cleanupCall();
        els.viewerSection.classList.add('hidden');
        els.usernameSection.classList.remove('hidden');
        showUsernameError('Connection lost — tap Join live stream to reconnect.');
      }
    });
  }

  async function verifyPassword() {
    if (!useWS || passwordBusy) return;
    const password = (els.passwordInput?.value || defaultPassword).trim();
    if (!password) {
      showPasswordError('Enter the viewer password.');
      return;
    }

    if (password !== defaultPassword) {
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
      try { sessionStorage.setItem('mdvc-viewer-password', password); } catch { /* ignore */ }
      showPasswordError('');
      if (!live.relayOnline) {
        setStatus('waiting', 'Password OK — waiting for cast on phone');
        if (els.usernameStatusText) {
          els.usernameStatusText.textContent = 'Password accepted. You can join now — stream will start when Live Stream begins on glasses.';
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
    const password = verifiedPassword || (els.passwordInput?.value || defaultPassword).trim();
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
      showViewerStep();
      if (joined.streaming) {
        setViewerStatus('waiting', 'Stream in progress — connecting video…');
      }
    } catch (err) {
      showUsernameError(err.message || 'Could not join.');
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

  try {
    const savedName = sessionStorage.getItem('mdvc-viewer-name');
    if (savedName && els.usernameInput && !els.usernameInput.value) {
      els.usernameInput.value = savedName;
    }
  } catch { /* ignore */ }

  setStatus('waiting', 'Enter password to continue');
})();
