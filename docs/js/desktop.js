/**
 * Public viewer — password, then username, cast window + live chat.
 */
(function () {
  const useWS = !!(window.CASTER_CONFIG?.SIGNALING_URL || window.CASTER_CONFIG?.SIGNALING_HOST);
  const defaultPassword = window.CASTER_CONFIG?.VIEWER_PASSWORD || 'Wedding';

  const WAITING_CAST = 'Waiting For Live Cast';
  const LIVE_REFRESH_HINT = 'If Stream is Live and no stream is showing, please refresh page!';

  function waitingStatusText() {
    return viewerName ? `Hi ${viewerName} — Waiting For Live Cast` : WAITING_CAST;
  }

  function liveStatusText() {
    return viewerName ? `Hi ${viewerName} — Stream is Live!` : 'Stream is Live!';
  }

  function showWaitingCastUi() {
    if (hasHealthyVideo()) return;
    setVideoPlaceholder(WAITING_CAST);
    setViewerStatus('waiting', waitingStatusText());
    if (els.captureHint) els.captureHint.textContent = '';
  }

  function showLiveViewerUi() {
    setViewerStatus('connected', liveStatusText());
    if (els.captureHint) els.captureHint.textContent = LIVE_REFRESH_HINT;
  }

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
    gifBtn: document.getElementById('gif-btn'),
    gifPanel: document.getElementById('gif-panel'),
    gifPresets: document.getElementById('gif-presets'),
    gifUrlInput: document.getElementById('gif-url-input'),
    gifUrlSend: document.getElementById('gif-url-send'),
    chatToolsBtn: document.getElementById('chat-tools-btn'),
    chatToolsMenu: document.getElementById('chat-tools-menu'),
    emojiBtn: document.getElementById('emoji-btn'),
    emojiPanel: document.getElementById('emoji-panel'),
    emojiGrid: document.getElementById('emoji-grid'),
    photoBtn: document.getElementById('photo-btn'),
    photoInput: document.getElementById('photo-input'),
  };

  const CHAT_IMAGE_MAX_CHARS = 600000;

  const EMOJI_LIST = [
    '😀', '😃', '😄', '😁', '😆', '😅', '🤣', '😂', '🙂', '🙃',
    '😉', '😊', '😇', '🥰', '😍', '🤩', '😘', '😗', '😚', '😙',
    '🥲', '😋', '😛', '😜', '🤪', '😝', '🤑', '🤗', '🤭', '🤫',
    '🤔', '🤐', '🤨', '😐', '😑', '😶', '😏', '😒', '🙄', '😬',
    '😌', '😔', '😪', '🤤', '😴', '😷', '🤒', '🤕', '🤢', '🤮',
    '🥳', '😎', '🤓', '🧐', '😕', '😟', '🙁', '😮', '😯', '😲',
    '😳', '🥺', '😦', '😧', '😨', '😰', '😥', '😢', '😭', '😱',
    '😖', '😣', '😞', '😓', '😩', '😫', '🥱', '😤', '😡', '😠',
    '🤬', '😈', '👿', '💀', '☠️', '💩', '🤡', '👹', '👺', '👻',
    '👽', '👾', '🤖', '😺', '😸', '😹', '😻', '😼', '😽', '🙀',
    '😿', '😾', '🙈', '🙉', '🙊', '💋', '💌', '💘', '💝', '💖',
    '💗', '💓', '💞', '💕', '💟', '❣️', '💔', '❤️', '🧡', '💛',
    '💚', '💙', '💜', '🖤', '🤍', '🤎', '💯', '💢', '💥', '💫',
    '💦', '💨', '🕳️', '💣', '💬', '👁️‍🗨️', '🗨️', '🗯️', '💭', '💤',
    '👋', '🤚', '🖐️', '✋', '🖖', '👌', '🤌', '🤏', '✌️', '🤞',
    '🤟', '🤘', '🤙', '👈', '👉', '👆', '🖕', '👇', '☝️', '👍',
    '👎', '✊', '👊', '🤛', '🤜', '👏', '🙌', '👐', '🤲', '🤝',
    '🙏', '✍️', '💅', '🤳', '💪', '🦾', '🦿', '🦵', '🦶', '👂',
    '🎉', '🎊', '🎈', '🎁', '🎀', '🎂', '🍰', '🥂', '🍾', '🥳',
    '✨', '⭐', '🌟', '💫', '🔥', '👀', '🙏', '🫶', '🤍', '💍',
  ];

  const GIF_PRESETS = [
    { url: 'https://media.giphy.com/media/ICOgCUypo64o/giphy.gif', label: 'Celebrate' },
    { url: 'https://media.giphy.com/media/l0MYt5jPR6QX5pnqM/giphy.gif', label: 'Clap' },
    { url: 'https://media.giphy.com/media/3o7aCTPPm4OHfRLSH6/giphy.gif', label: 'Wow' },
    { url: 'https://media.giphy.com/media/26BRuo6sKejj0c9Vm/giphy.gif', label: 'Love' },
    { url: 'https://media.giphy.com/media/l3q2K5jinAlChoCLS/giphy.gif', label: 'Laugh' },
    { url: 'https://media.giphy.com/media/3o6Zt4HU9qdCo5XaBa/giphy.gif', label: 'Dance' },
    { url: 'https://media.giphy.com/media/13CoXDiaCcGyqI/giphy.gif', label: 'Thumbs up' },
    { url: 'https://media.giphy.com/media/5GoVLqeAw9FaBiNGxD/giphy.gif', label: 'Party' },
  ];

  let ws = null;
  let pc = null;
  let viewerId = null;
  let viewerName = '';
  let verifiedPassword = '';
  let connected = false;
  let relayOnline = false;
  let streamPending = false;
  let streamActive = false;
  let passwordBusy = false;
  let joinBusy = false;
  const chatSeen = new Set();
  let offerWatchdog = null;
  let controlsHideTimer = null;
  let livePollTimer = null;
  let videoHealthTimer = null;
  let noVideoStreak = 0;
  let lastOfferAt = 0;
  let restoreAttempted = false;

  const SESSION_KEYS = {
    auth: 'mdvc-viewer-auth',
    name: 'mdvc-viewer-name',
    joined: 'mdvc-viewer-joined',
  };

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
    showWaitingCastUi();
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
    item.dataset.chatId = msg.id;
    if (msg.viewerId === viewerId) item.classList.add('is-self');

    const name = document.createElement('span');
    name.className = 'chat-message-name';
    name.textContent = msg.name || 'Guest';

    if (msg.kind === 'gif' && (msg.gifUrl || msg.text)) {
      const img = document.createElement('img');
      img.className = 'chat-message-gif';
      img.src = msg.gifUrl || msg.text;
      img.alt = 'GIF';
      img.loading = 'lazy';
      item.append(name, img);
    } else if (msg.kind === 'image' && (msg.imageUrl || msg.text)) {
      const img = document.createElement('img');
      img.className = 'chat-message-image';
      img.src = msg.imageUrl || msg.text;
      img.alt = 'Photo';
      img.loading = 'lazy';
      item.append(name, img);
    } else {
      const text = document.createElement('span');
      text.className = 'chat-message-text';
      text.textContent = msg.text || '';
      item.append(name, text);
    }

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

  function sendChatGif(gifUrl) {
    const url = String(gifUrl || '').trim();
    if (!url || !ws || ws.readyState !== WebSocket.OPEN) return;
    ws.send(JSON.stringify({ type: 'chat-message', kind: 'gif', gifUrl: url }));
    hideChatPickers();
    els.gifUrlInput.value = '';
  }

  function sendChatEmoji(emoji) {
    const value = String(emoji || '').trim();
    if (!value || !ws || ws.readyState !== WebSocket.OPEN) return;
    sendChatMessage(value);
    hideChatPickers();
  }

  function sendChatImage(imageUrl) {
    const url = String(imageUrl || '').trim();
    if (!url || !ws || ws.readyState !== WebSocket.OPEN) return;
    if (url.length > CHAT_IMAGE_MAX_CHARS) {
      window.alert('That photo is too large. Try a smaller image.');
      return;
    }
    ws.send(JSON.stringify({ type: 'chat-message', kind: 'image', imageUrl: url }));
    hideChatPickers();
  }

  async function compressImageFile(file) {
    if (!file || !String(file.type || '').startsWith('image/')) {
      throw new Error('Choose a photo to upload.');
    }
    const bitmap = await createImageBitmap(file);
    const maxWidth = 1280;
    let width = bitmap.width;
    let height = bitmap.height;
    if (width > maxWidth) {
      height = Math.round(height * (maxWidth / width));
      width = maxWidth;
    }
    const canvas = document.createElement('canvas');
    canvas.width = width;
    canvas.height = height;
    const ctx = canvas.getContext('2d');
    if (!ctx) {
      bitmap.close();
      throw new Error('Could not process that photo.');
    }
    ctx.drawImage(bitmap, 0, 0, width, height);
    bitmap.close();

    let quality = 0.88;
    let dataUrl = canvas.toDataURL('image/jpeg', quality);
    while (dataUrl.length > CHAT_IMAGE_MAX_CHARS && quality > 0.35) {
      quality -= 0.08;
      dataUrl = canvas.toDataURL('image/jpeg', quality);
    }
    if (dataUrl.length > CHAT_IMAGE_MAX_CHARS) {
      throw new Error('That photo is too large. Try a smaller image.');
    }
    return dataUrl;
  }

  async function handlePhotoSelected(file) {
    if (!file) return;
    try {
      const dataUrl = await compressImageFile(file);
      sendChatImage(dataUrl);
    } catch (err) {
      window.alert(err.message || 'Could not send that photo.');
    }
  }

  function hideChatToolsMenu() {
    els.chatToolsMenu?.classList.add('hidden');
    els.chatToolsBtn?.setAttribute('aria-expanded', 'false');
  }

  function toggleChatToolsMenu() {
    if (!els.chatToolsMenu) return;
    const willOpen = els.chatToolsMenu.classList.contains('hidden');
    if (willOpen) {
      els.chatToolsMenu.classList.remove('hidden');
      els.chatToolsBtn?.setAttribute('aria-expanded', 'true');
    } else {
      hideChatToolsMenu();
    }
  }

  function hideChatPickers(except = null) {
    if (except !== 'gif') els.gifPanel?.classList.add('hidden');
    if (except !== 'emoji') els.emojiPanel?.classList.add('hidden');
    hideChatToolsMenu();
  }

  function requestViewerOffer() {
    if (!ws || ws.readyState !== WebSocket.OPEN || !viewerId) return;
    ws.send(JSON.stringify({ type: 'viewer-needs-offer' }));
  }

  function clearOfferWatchdog() {
    if (offerWatchdog) {
      clearTimeout(offerWatchdog);
      offerWatchdog = null;
    }
  }

  function scheduleOfferWatchdog() {
    clearOfferWatchdog();
    offerWatchdog = setTimeout(() => {
      if (!hasHealthyVideo() && (streamPending || streamActive || relayOnline)) {
        requestViewerOffer();
        scheduleOfferWatchdog();
      }
    }, 3000);
  }

  function hasHealthyVideo() {
    const video = els.remoteVideo;
    const stream = video?.srcObject;
    if (!video || !stream) return false;
    const track = stream.getVideoTracks()[0];
    if (!track || track.readyState !== 'live') return false;
    if (video.videoWidth > 0 && video.videoHeight > 0) return true;
    if (pc && (pc.connectionState === 'connected' || pc.iceConnectionState === 'connected' || pc.iceConnectionState === 'completed')) {
      return false;
    }
    return false;
  }

  function startVideoHealthWatch() {
    stopVideoHealthWatch();
    noVideoStreak = 0;
    videoHealthTimer = setInterval(() => {
      if (!connected) return;
      if (hasHealthyVideo()) {
        noVideoStreak = 0;
        return;
      }
      if (!streamActive && !streamPending && !els.remoteVideo?.srcObject) return;
      noVideoStreak += 1;
      if (noVideoStreak >= 2) {
        forceStreamReconnect();
      }
    }, 3000);
  }

  function stopVideoHealthWatch() {
    if (videoHealthTimer) {
      clearInterval(videoHealthTimer);
      videoHealthTimer = null;
    }
    noVideoStreak = 0;
  }

  function forceStreamReconnect() {
    stopVideoHealthWatch();
    clearOfferWatchdog();
    pc?.close();
    pc = null;
    if (els.remoteVideo) els.remoteVideo.srcObject = null;
    streamPending = true;
    streamActive = true;
    relayOnline = true;
    showWaitingCastUi();
    requestViewerOffer();
    scheduleOfferWatchdog();
  }

  function onStreamLost() {
    if (!streamActive && !streamPending) return;
    forceStreamReconnect();
  }

  function beginStreamConnect() {
    if (hasHealthyVideo()) return;
    if (els.remoteVideo?.srcObject) {
      forceStreamReconnect();
      return;
    }
    streamPending = true;
    relayOnline = true;
    requestViewerOffer();
    scheduleOfferWatchdog();
  }

  function markStreamLive() {
    streamActive = true;
    streamPending = true;
    relayOnline = true;
  }

  function startLivePoll() {
    stopLivePoll();
    livePollTimer = setInterval(async () => {
      if (!connected || hasHealthyVideo()) {
        stopLivePoll();
        return;
      }
      try {
        const live = await CasterWS.fetchLiveStatus();
        if (live.relayOnline) relayOnline = true;
        if (live.streaming) {
          markStreamLive();
          beginStreamConnect();
        } else if (relayOnline) {
          updateWaitingState();
        }
      } catch { /* ignore */ }
    }, 4000);
  }

  function stopLivePoll() {
    if (livePollTimer) {
      clearInterval(livePollTimer);
      livePollTimer = null;
    }
  }

  function updateMuteButton() {
    if (!els.unmuteBtn || !els.remoteVideo) return;
    const muted = els.remoteVideo.muted;
    els.unmuteBtn.textContent = muted ? '🔇' : '🔊';
    els.unmuteBtn.classList.toggle('is-unmuted', !muted);
    els.unmuteBtn.title = muted ? 'Unmute' : 'Mute';
    els.unmuteBtn.setAttribute('aria-label', muted ? 'Unmute' : 'Mute');
  }

  function showVideoControls() {
    if (!els.videoWrap) return;
    els.videoWrap.classList.add('show-controls');
    if (controlsHideTimer) clearTimeout(controlsHideTimer);
    controlsHideTimer = setTimeout(() => {
      els.videoWrap?.classList.remove('show-controls');
    }, 3200);
  }

  function initGifPresets() {
    if (!els.gifPresets) return;
    els.gifPresets.innerHTML = '';
    for (const preset of GIF_PRESETS) {
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'gif-preset-btn';
      btn.title = preset.label;
      const img = document.createElement('img');
      img.src = preset.url;
      img.alt = preset.label;
      img.loading = 'lazy';
      btn.appendChild(img);
      btn.addEventListener('click', () => sendChatGif(preset.url));
      els.gifPresets.appendChild(btn);
    }
  }

  function initEmojiPicker() {
    if (!els.emojiGrid) return;
    els.emojiGrid.innerHTML = '';
    for (const emoji of EMOJI_LIST) {
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'emoji-preset-btn';
      btn.textContent = emoji;
      btn.title = emoji;
      btn.addEventListener('click', () => sendChatEmoji(emoji));
      els.emojiGrid.appendChild(btn);
    }
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

  function onStreamActive(stream, track) {
    clearOfferWatchdog();
    stopLivePoll();
    streamPending = false;
    streamActive = true;
    relayOnline = true;
    noVideoStreak = 0;
    els.remoteVideo.srcObject = stream;
    els.videoPlaceholder.classList.add('hidden');
    els.remoteVideo.muted = true;
    updateMuteButton();
    const playPromise = els.remoteVideo.play();
    if (playPromise?.catch) playPromise.catch(() => {});
    if (track) {
      track.onunmute = () => {
        els.remoteVideo.play().catch(() => {});
      };
    }
    const hasAudio = stream.getAudioTracks().length > 0;
    showLiveViewerUi();
    if (hasAudio && els.captureHint) {
      els.captureHint.textContent = `${LIVE_REFRESH_HINT}\nTap the stream for sound and fullscreen controls.`;
    }
    scrollToVideo();
    showVideoControls();
    startVideoHealthWatch();
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
    clearOfferWatchdog();
    stopVideoHealthWatch();
    streamPending = false;
    streamActive = false;
    pc?.close();
    pc = null;
    els.remoteVideo.srcObject = null;
    updateWaitingState();
  }

  function bindWsMessages() {
    ws.addEventListener('message', async (ev) => {
      let msg;
      try { msg = JSON.parse(ev.data); } catch { return; }

      if (msg.type === 'error') {
        console.warn('Signaling error:', msg.message);
        if (String(msg.message || '').includes('viewer-needs-offer') || String(msg.message || '').startsWith('Unknown:')) {
          if (els.captureHint && streamPending) {
            els.captureHint.textContent = 'Signaling server may need a redeploy on Render — retrying…';
          }
        }
        return;
      }

      if (msg.type === 'viewer-list-updated') {
        renderViewerRoster(msg.viewers);
        const list = Array.isArray(msg.viewers) ? msg.viewers : [];
        const anyoneWatching = list.some((v) => v.status === 'watching');
        const selfWatching = list.some((v) => v.viewerId === viewerId && v.status === 'watching');
        if (anyoneWatching || selfWatching) {
          markStreamLive();
          if (!hasHealthyVideo()) beginStreamConnect();
        }
      }

      if (msg.type === 'chat-message') {
        appendChatMessage(msg);
      }

      if (msg.type === 'chat-cleared') {
        chatSeen.clear();
        loadChatHistory([]);
      }

      if (msg.type === 'chat-message-deleted') {
        if (!msg.id || !els.chatMessages) return;
        chatSeen.delete(msg.id);
        const node = els.chatMessages.querySelector(`[data-chat-id="${msg.id}"]`);
        node?.remove();
        renderChatEmpty();
      }

      if (msg.type === 'relay-online') {
        relayOnline = true;
        updateWaitingState();
        if (connected && !hasHealthyVideo()) {
          beginStreamConnect();
        }
      }

      if (msg.type === 'glasses-joined') {
        if (relayOnline) updateWaitingState();
      }

      if (msg.type === 'offer') {
        const now = Date.now();
        if (hasHealthyVideo() && now - lastOfferAt < 15000) {
          return;
        }
        lastOfferAt = now;
        clearOfferWatchdog();
        if (pc) {
          pc.close();
          pc = null;
        }
        pc = CasterWebRTCViewer.createPeerConnection(onStreamActive, onStreamLost);
        CasterWebRTCViewer.bindIce(pc, ws, viewerId);
        try {
          await CasterWebRTCViewer.handleOffer(pc, ws, msg, viewerId);
        } catch (err) {
          console.warn('Offer handling failed, retrying…', err);
          pc?.close();
          pc = null;
          markStreamLive();
          requestViewerOffer();
          scheduleOfferWatchdog();
        }
      }

      if (msg.type === 'ice-candidate' && pc) {
        await CasterWebRTCViewer.handleRemoteIce(pc, msg);
      }

      if (msg.type === 'stream-started') {
        markStreamLive();
        if (!hasHealthyVideo()) {
          scrollToVideo();
          beginStreamConnect();
        }
      }

      if (msg.type === 'stream-starting') {
        markStreamLive();
        if (!hasHealthyVideo()) {
          scrollToVideo();
          beginStreamConnect();
        }
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
      stopLivePoll();
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
      try { sessionStorage.setItem(SESSION_KEYS.auth, password); } catch { /* ignore */ }
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
      try {
        sessionStorage.setItem(SESSION_KEYS.name, name);
        sessionStorage.setItem(SESSION_KEYS.joined, '1');
      } catch { /* ignore */ }
      bindWsMessages();
      connected = true;
      renderViewerRoster(joined.viewers);
      loadChatHistory(joined.chatHistory);
      showViewerStep({
        relayOnline: joined.relayOnline,
        streaming: joined.streaming,
      });
      startLivePoll();
      if (joined.streaming) {
        markStreamLive();
        scrollToVideo();
        beginStreamConnect();
      } else if (joined.relayOnline) {
        beginStreamConnect();
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

  els.unmuteBtn?.addEventListener('click', (e) => {
    e.stopPropagation();
    els.remoteVideo.muted = !els.remoteVideo.muted;
    updateMuteButton();
    showVideoControls();
  });

  els.fullscreenBtn?.addEventListener('click', (e) => {
    e.stopPropagation();
    enterFullscreen();
    showVideoControls();
  });

  els.videoWrap?.addEventListener('click', (e) => {
    if (e.target.closest('.video-icon-btn')) return;
    if (els.remoteVideo?.srcObject) showVideoControls();
  });

  els.chatToolsBtn?.addEventListener('click', (e) => {
    e.stopPropagation();
    toggleChatToolsMenu();
  });

  document.addEventListener('click', () => {
    hideChatToolsMenu();
  });

  els.chatToolsMenu?.addEventListener('click', (e) => {
    e.stopPropagation();
  });

  els.gifBtn?.addEventListener('click', (e) => {
    e.stopPropagation();
    hideChatToolsMenu();
    const opening = els.gifPanel?.classList.contains('hidden');
    hideChatPickers(opening ? 'gif' : null);
    if (opening) {
      els.gifPanel?.classList.remove('hidden');
      els.gifUrlInput?.focus();
    }
  });

  els.emojiBtn?.addEventListener('click', (e) => {
    e.stopPropagation();
    hideChatToolsMenu();
    const opening = els.emojiPanel?.classList.contains('hidden');
    hideChatPickers(opening ? 'emoji' : null);
    if (opening) {
      els.emojiPanel?.classList.remove('hidden');
    }
  });

  els.photoBtn?.addEventListener('click', (e) => {
    e.stopPropagation();
    hideChatToolsMenu();
    hideChatPickers();
    els.photoInput?.click();
  });

  els.photoInput?.addEventListener('change', () => {
    const file = els.photoInput?.files?.[0];
    if (els.photoInput) els.photoInput.value = '';
    handlePhotoSelected(file);
  });

  els.gifUrlSend?.addEventListener('click', () => {
    sendChatGif(els.gifUrlInput?.value || '');
  });

  els.gifUrlInput?.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      sendChatGif(els.gifUrlInput?.value || '');
    }
  });

  async function tryRestoreSession() {
    if (restoreAttempted || !useWS) return;
    restoreAttempted = true;
    try {
      const savedAuth = sessionStorage.getItem(SESSION_KEYS.auth);
      const savedName = sessionStorage.getItem(SESSION_KEYS.name);
      if (!savedAuth || !passwordsMatch(savedAuth, defaultPassword)) return;

      verifiedPassword = savedAuth;
      if (savedName && els.usernameInput && !els.usernameInput.value) {
        els.usernameInput.value = savedName;
      }

      const wasJoined = sessionStorage.getItem(SESSION_KEYS.joined) === '1';
      if (wasJoined && savedName) {
        setStatus('waiting', 'Welcome back — reconnecting…');
        await joinWithUsername();
        return;
      }

      showUsernameStep();
      setStatus('waiting', 'Welcome back — enter your name to join');
    } catch {
      /* ignore restore errors */
    }
  }

  initGifPresets();
  initEmojiPicker();
  updateMuteButton();

  els.chatForm?.addEventListener('submit', (e) => {
    e.preventDefault();
    const text = (els.chatInput?.value || '').trim();
    if (!text) return;
    sendChatMessage(text);
    els.chatInput.value = '';
    els.chatInput.focus();
  });

  try {
    const savedName = sessionStorage.getItem(SESSION_KEYS.name);
    if (savedName && els.usernameInput && !els.usernameInput.value) {
      els.usernameInput.value = savedName;
    }
  } catch { /* ignore */ }

  const hasSavedAuth = (() => {
    try { return !!sessionStorage.getItem(SESSION_KEYS.auth); } catch { return false; }
  })();
  if (!hasSavedAuth) {
    setStatus('waiting', 'Enter password to continue');
  }
  tryRestoreSession().catch(() => {});
})();
