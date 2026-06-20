/**
 * Glasses UI — connects outbound to phone relay (no custom peer ID needed).
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
    codeForm: document.getElementById('code-form'),
    codeInput: document.getElementById('code-input'),
    joinBtn: document.getElementById('join-btn'),
  };

  let peer = null;
  let dataConn = null;
  let connected = false;
  let streaming = false;
  let currentCode = presetCode || '';

  function setStatus(kind, text) {
    els.status.className = `status ${kind}`;
    els.statusText.textContent = text;
  }

  function showConnected() {
    connected = true;
    els.pairingView.classList.add('hidden');
    els.connectedView.classList.remove('hidden');
    els.connectedLabel.textContent = 'Connected';
    els.sessionCode.textContent = currentCode;
    els.streamHint.textContent = 'Tap Live Stream to cast to desktop.';
    setStatus('connected', 'Linked to desktop');
    els.streamBtn.focus();
  }

  async function joinRelay(code) {
    currentCode = code;
    els.joinBtn.disabled = true;
    setStatus('waiting', 'Connecting…');

    try {
      peer?.destroy();
      peer = await CasterSignaling.createPeerWithRetry();
      dataConn = peer.connect(CasterSignaling.peerIdForCode(code), { reliable: true });
      await CasterSignaling.waitForConnection(dataConn, 20000);
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
      setStatus('error', 'Could not connect. Check code from phone relay.');
      els.joinBtn.disabled = false;
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

  els.streamBtn.addEventListener('click', toggleStream);
  els.streamBtn.addEventListener('keydown', (e) => { if (e.key === 'Enter') toggleStream(); });
  els.joinBtn?.addEventListener('click', () => {
    const code = (els.codeInput?.value || '').replace(/\D/g, '').slice(0, 6);
    if (code.length === 6) joinRelay(code);
  });

  if (presetCode?.length === 6) {
    els.pairCode.textContent = presetCode;
    joinRelay(presetCode);
  } else if (els.codeForm) {
    setStatus('waiting', 'Enter code from phone relay');
    els.codeTimer.textContent = 'Open relay.html on your phone first';
  } else {
    setStatus('waiting', 'Open relay.html on phone, then add ?code=XXXXXX to this URL');
  }
})();
