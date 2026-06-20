/**
 * Glasses UI — Meta Display input (↑↓←→ + Enter, no click grid)
 */
(function () {
  const params = new URLSearchParams(location.search);
  const presetCode = params.get('code')?.replace(/\D/g, '').slice(0, 6);

  const els = {
    pairingView: document.getElementById('pairing-view'),
    connectedView: document.getElementById('connected-view'),
    codeTimer: document.getElementById('code-timer'),
    status: document.getElementById('status'),
    statusText: document.getElementById('status-text'),
    connectedLabel: document.getElementById('connected-label'),
    streamHint: document.getElementById('stream-hint'),
    streamBtn: document.getElementById('stream-btn'),
    sessionCode: document.getElementById('session-code'),
    codePicker: document.getElementById('code-picker'),
    codeSlots: document.getElementById('code-slots'),
    joinBtn: document.getElementById('join-btn'),
    backspaceBtn: document.getElementById('backspace-btn'),
  };

  const SLOT_COUNT = 6;
  const KEY_COOLDOWN_MS = 450;

  let slots = Array(SLOT_COUNT).fill(0);
  let slotIndex = 0;
  let peer = null;
  let dataConn = null;
  let connected = false;
  let streaming = false;
  let lastKeyAction = { key: '', at: 0 };

  if (presetCode.length === SLOT_COUNT) {
    slots = presetCode.split('').map((d) => parseInt(d, 10));
  }

  function setStatus(kind, text) {
    els.status.className = `status ${kind}`;
    els.statusText.textContent = text;
  }

  function codeString() {
    return slots.map(String).join('');
  }

  function renderSlots() {
    els.codeSlots.innerHTML = slots.map((digit, i) => {
      const active = i === slotIndex ? ' code-slot-active' : '';
      return `<span class="code-slot${active}" data-index="${i}">${digit}</span>`;
    }).join('');
  }

  function isDuplicateKey(key) {
    if (key === 'Unidentified') return false;
    const now = Date.now();
    if (lastKeyAction.key === key && now - lastKeyAction.at < KEY_COOLDOWN_MS) {
      return true;
    }
    lastKeyAction = { key, at: now };
    return false;
  }

  function bumpDigit(delta) {
    slots[slotIndex] = (slots[slotIndex] + delta + 10) % 10;
    renderSlots();
  }

  function moveSlot(delta) {
    slotIndex = Math.max(0, Math.min(SLOT_COUNT - 1, slotIndex + delta));
    renderSlots();
  }

  function backspace() {
    if (slots[slotIndex] !== 0) {
      slots[slotIndex] = 0;
    } else if (slotIndex > 0) {
      slotIndex -= 1;
      slots[slotIndex] = 0;
    }
    renderSlots();
    els.codePicker.focus();
  }

  function bindEnterOnly(el, fn) {
    if (!el) return;
    el.addEventListener('keydown', (e) => {
      if (e.key !== 'Enter') return;
      if (e.repeat || isDuplicateKey('Enter-btn')) return;
      e.preventDefault();
      e.stopImmediatePropagation();
      fn();
    });
    el.addEventListener('click', (e) => {
      e.preventDefault();
      e.stopImmediatePropagation();
    });
  }

  function handlePickerKey(e) {
    if (connected) return;

    const key = e.key;
    if (e.repeat) {
      e.preventDefault();
      return;
    }
    if (isDuplicateKey(`picker-${key}`)) {
      e.preventDefault();
      return;
    }

    switch (key) {
      case 'ArrowUp':
        e.preventDefault();
        bumpDigit(1);
        break;
      case 'ArrowDown':
        e.preventDefault();
        bumpDigit(-1);
        break;
      case 'ArrowRight':
        e.preventDefault();
        moveSlot(1);
        break;
      case 'ArrowLeft':
        e.preventDefault();
        moveSlot(-1);
        break;
      case 'Backspace':
        e.preventDefault();
        backspace();
        break;
      case 'Enter':
        e.preventDefault();
        e.stopImmediatePropagation();
        if (slotIndex < SLOT_COUNT - 1) {
          moveSlot(1);
        } else {
          els.joinBtn.focus();
        }
        break;
      default:
        break;
    }
  }

  function setupPickerKeys() {
    els.codePicker.addEventListener('keydown', handlePickerKey);
  }

  function showConnected() {
    connected = true;
    els.pairingView.classList.add('hidden');
    els.connectedView.classList.remove('hidden');
    els.connectedLabel.textContent = 'Connected';
    els.sessionCode.textContent = codeString();
    els.streamHint.textContent = 'Select Live Stream, press Enter';
    setStatus('connected', 'Linked to desktop');
    els.streamBtn.focus();
  }

  async function joinRelay() {
    const code = codeString();
    els.joinBtn.disabled = true;
    setStatus('waiting', 'Connecting…');

    try {
      peer?.destroy();
      peer = await CasterSignaling.createPeerWithRetry();
      dataConn = peer.connect(CasterSignaling.peerIdForCode(code), { reliable: true });
      await CasterSignaling.waitForConnection(dataConn, 25000);

      dataConn.on('data', (msg) => {
        if (msg?.type === 'stream-started') {
          streaming = true;
          els.streamBtn.textContent = 'Stop Stream';
          els.streamBtn.classList.add('active');
          els.streamHint.textContent = 'Casting…';
        }
        if (msg?.type === 'stop-stream') {
          streaming = false;
          els.streamBtn.textContent = 'Live Stream';
          els.streamBtn.classList.remove('active');
          els.streamHint.textContent = 'Select Live Stream, press Enter';
        }
      });

      dataConn.on('close', () => {
        connected = false;
        setStatus('error', 'Disconnected');
        els.joinBtn.disabled = false;
      });

      showConnected();
    } catch (err) {
      console.error(err);
      setStatus('error', 'Could not connect. Check code on phone relay.');
      els.joinBtn.disabled = false;
      els.codePicker.focus();
    }
  }

  function toggleStream() {
    if (!connected || !dataConn?.open) return;
    if (streaming) {
      CasterSignaling.sendData(dataConn, { type: 'stop-stream' });
      streaming = false;
      els.streamBtn.textContent = 'Live Stream';
      els.streamBtn.classList.remove('active');
    } else {
      CasterSignaling.sendData(dataConn, { type: 'start-stream' });
    }
  }

  bindEnterOnly(els.backspaceBtn, backspace);
  bindEnterOnly(els.joinBtn, joinRelay);
  bindEnterOnly(els.streamBtn, toggleStream);
  setupPickerKeys();

  renderSlots();
  els.codePicker.focus();

  if (presetCode.length === SLOT_COUNT) {
    joinRelay();
  } else {
    setStatus('waiting', 'Enter code from phone relay');
  }
})();
