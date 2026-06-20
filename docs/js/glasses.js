/**
 * Glasses UI — digit pad for Meta Display (Enter only, no click)
 */
(function () {
  const params = new URLSearchParams(location.search);
  const presetCode = params.get('code')?.replace(/\D/g, '').slice(0, 6);

  const els = {
    pairingView: document.getElementById('pairing-view'),
    connectedView: document.getElementById('connected-view'),
    status: document.getElementById('status'),
    statusText: document.getElementById('status-text'),
    connectedLabel: document.getElementById('connected-label'),
    streamHint: document.getElementById('stream-hint'),
    streamBtn: document.getElementById('stream-btn'),
    sessionCode: document.getElementById('session-code'),
    digitDisplay: document.getElementById('digit-display'),
    backspaceBtn: document.getElementById('backspace-btn'),
    joinBtn: document.getElementById('join-btn'),
  };

  const KEY_COOLDOWN_MS = 450;

  let peer = null;
  let dataConn = null;
  let connected = false;
  let streaming = false;
  let digits = presetCode || '';
  let lastKeyAction = { key: '', at: 0 };

  function setStatus(kind, text) {
    els.status.className = `status ${kind}`;
    els.statusText.textContent = text;
  }

  function renderDigits() {
    const padded = (digits + '------').slice(0, 6);
    if (els.digitDisplay) els.digitDisplay.textContent = padded;
  }

  function isDuplicateKey(key) {
    const now = Date.now();
    if (lastKeyAction.key === key && now - lastKeyAction.at < KEY_COOLDOWN_MS) {
      return true;
    }
    lastKeyAction = { key, at: now };
    return false;
  }

  function pressDigit(d) {
    if (isDuplicateKey(`digit-${d}`)) return;
    if (digits.length < 6) digits += d;
    renderDigits();
  }

  function backspace() {
    if (isDuplicateKey('backspace')) return;
    digits = digits.slice(0, -1);
    renderDigits();
  }

  function bindEnterOnly(el, fn) {
    if (!el) return;
    el.addEventListener('keydown', (e) => {
      if (e.key !== 'Enter') return;
      if (e.repeat) {
        e.preventDefault();
        return;
      }
      e.preventDefault();
      e.stopImmediatePropagation();
      fn();
    });
    el.addEventListener('click', (e) => {
      e.preventDefault();
      e.stopImmediatePropagation();
    });
  }

  function showConnected() {
    connected = true;
    els.pairingView.classList.add('hidden');
    els.connectedView.classList.remove('hidden');
    els.connectedLabel.textContent = 'Connected';
    els.sessionCode.textContent = digits;
    els.streamHint.textContent = 'Select Live Stream, press Enter';
    setStatus('connected', 'Linked to desktop');
    els.streamBtn.focus();
  }

  function waitForRelayAck(conn, ms = 20000) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        conn.off('data', onData);
        reject(new Error('Desktop not ready. Tap Connect on desktop first, then try Go again.'));
      }, ms);
      function onData(msg) {
        if (msg?.type === 'relay-ack') {
          clearTimeout(timer);
          conn.off('data', onData);
          resolve();
        }
      }
      conn.on('data', onData);
    });
  }

  async function joinDesktop() {
    const code = digits.replace(/\D/g, '').slice(0, 6);
    if (code.length !== 6) return;

    els.joinBtn.disabled = true;
    setStatus('waiting', 'Connecting…');

    const maxAttempts = 3;
    let lastError;

    for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
      try {
        peer?.destroy();
        peer = await CasterSignaling.createPeerWithRetry();
        dataConn = peer.connect(CasterSignaling.peerIdForCode(code), { reliable: true });
        await CasterSignaling.waitForConnection(dataConn, 30000);

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

        CasterSignaling.sendData(dataConn, { type: 'hello', role: 'glasses', peerId: peer.id });
        await waitForRelayAck(dataConn);
        showConnected();
        return;
      } catch (err) {
        lastError = err;
        console.warn(`join attempt ${attempt}`, err);
        if (attempt < maxAttempts) {
          setStatus('waiting', `Retrying… (${attempt + 1}/${maxAttempts})`);
          await new Promise((r) => setTimeout(r, 2000));
        }
      }
    }

    console.error(lastError);
    setStatus('error', lastError?.message || 'Could not connect. Connect desktop first.');
    els.joinBtn.disabled = false;
  }

  function toggleStream() {
    if (!connected || !dataConn?.open) return;
    if (isDuplicateKey('stream')) return;

    if (streaming) {
      CasterSignaling.sendData(dataConn, { type: 'stop-stream' });
      streaming = false;
      els.streamBtn.textContent = 'Live Stream';
      els.streamBtn.classList.remove('active');
    } else {
      CasterSignaling.sendData(dataConn, { type: 'start-stream' });
    }
  }

  document.querySelectorAll('.digit-btn[data-digit]').forEach((btn) => {
    bindEnterOnly(btn, () => pressDigit(btn.dataset.digit));
  });

  bindEnterOnly(els.backspaceBtn, backspace);
  bindEnterOnly(els.joinBtn, joinDesktop);
  bindEnterOnly(els.streamBtn, toggleStream);

  renderDigits();

  if (presetCode.length === 6) {
    joinDesktop();
  } else {
    setStatus('waiting', 'Enter code from phone relay');
  }
})();
