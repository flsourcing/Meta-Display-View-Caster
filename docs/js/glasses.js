/**
 * Glasses UI — digit pad + connect to phone relay
 */
(function () {
  const params = new URLSearchParams(location.search);
  const presetCode = params.get('code')?.replace(/\D/g, '').slice(0, 6);

  const els = {
    pairingView: document.getElementById('pairing-view'),
    connectedView: document.getElementById('connected-view'),
    pairCode: document.getElementById('pair-code'),
    codeTimer: document.getElementById('code-timer'),
    status: document.getElementById('status'),
    statusText: document.getElementById('status-text'),
    connectedLabel: document.getElementById('connected-label'),
    streamHint: document.getElementById('stream-hint'),
    streamBtn: document.getElementById('stream-btn'),
    sessionCode: document.getElementById('session-code'),
    digitDisplay: document.getElementById('digit-display'),
    codeInput: document.getElementById('code-input'),
    joinBtn: document.getElementById('join-btn'),
  };

  let peer = null;
  let dataConn = null;
  let connected = false;
  let streaming = false;
  let digits = presetCode || '';
  let lastTapMs = 0;

  function setStatus(kind, text) {
    els.status.className = `status ${kind}`;
    els.statusText.textContent = text;
  }

  function renderDigits() {
    const padded = (digits + '------').slice(0, 6);
    if (els.digitDisplay) els.digitDisplay.textContent = padded;
    if (els.pairCode) els.pairCode.textContent = padded;
    if (els.codeInput) els.codeInput.value = digits;
  }

  function pressDigit(d) {
    const now = Date.now();
    if (now - lastTapMs < 350) return;
    lastTapMs = now;

    if (d === 'clear') digits = '';
    else if (digits.length < 6) digits += d;
    renderDigits();
  }

  function bindButton(btn, action) {
    btn.addEventListener('click', (e) => {
      e.preventDefault();
      action();
    });
  }

  document.querySelectorAll('.digit-btn[data-digit]').forEach((btn) => {
    bindButton(btn, () => pressDigit(btn.dataset.digit));
  });

  function showConnected() {
    connected = true;
    els.pairingView.classList.add('hidden');
    els.connectedView.classList.remove('hidden');
    els.connectedLabel.textContent = 'Connected';
    els.sessionCode.textContent = digits;
    els.streamHint.textContent = 'Tap Live Stream to cast to desktop.';
    setStatus('connected', 'Linked to desktop');
    els.streamBtn.focus();
  }

  async function joinRelay() {
    const code = digits.replace(/\D/g, '').slice(0, 6);
    if (code.length !== 6) return;

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
          els.streamHint.textContent = 'Tap Live Stream to cast to desktop.';
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
      setStatus('error', 'Could not connect. Check code matches phone relay.');
      els.joinBtn.disabled = false;
    }
  }

  function toggleStream() {
    if (!connected || !dataConn?.open) return;
    const now = Date.now();
    if (now - lastTapMs < 350) return;
    lastTapMs = now;

    if (streaming) {
      CasterSignaling.sendData(dataConn, { type: 'stop-stream' });
      streaming = false;
      els.streamBtn.textContent = 'Live Stream';
      els.streamBtn.classList.remove('active');
    } else {
      CasterSignaling.sendData(dataConn, { type: 'start-stream' });
    }
  }

  bindButton(els.streamBtn, toggleStream);
  bindButton(els.joinBtn, joinRelay);

  renderDigits();

  if (presetCode.length === 6) {
    joinRelay();
  } else {
    setStatus('waiting', 'Enter code from phone relay');
    els.codeTimer.textContent = 'Open relay.html on your phone first';
  }
})();
