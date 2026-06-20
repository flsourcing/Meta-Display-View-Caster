/**
 * Phone camera — streams to desktop
 */
(function () {
  const els = {
    codeInput: document.getElementById('code-input'),
    connectBtn: document.getElementById('connect-btn'),
    status: document.getElementById('status'),
    statusText: document.getElementById('status-text'),
    errorMsg: document.getElementById('error-msg'),
    readyView: document.getElementById('ready-view'),
    codeDisplay: document.getElementById('code-display'),
  };

  let peer = null;
  let localStream = null;
  let activeCall = null;

  function setStatus(kind, text) {
    els.status.className = `status ${kind}`;
    els.statusText.textContent = text;
  }

  function showError(msg) {
    els.errorMsg.textContent = msg || '';
    els.errorMsg.classList.toggle('error', !!msg);
  }

  function stopStream() {
    activeCall?.close();
    activeCall = null;
    localStream?.getTracks().forEach((t) => t.stop());
    localStream = null;
    setStatus('connected', 'Ready — tap Live Stream on glasses');
  }

  async function startStream(desktopPeerId) {
    stopStream();
    setStatus('waiting', 'Starting camera…');
    try {
      localStream = await navigator.mediaDevices.getUserMedia({
        video: { facingMode: 'environment', width: { ideal: 1280 }, height: { ideal: 720 } },
        audio: false,
      });
    } catch {
      showError('Allow camera access on your phone.');
      return;
    }
    activeCall = peer.call(desktopPeerId, localStream);
    activeCall.on('close', stopStream);
    setStatus('connected', 'Live stream active');
  }

  async function joinSession() {
    const code = (new URLSearchParams(location.search).get('code') || els.codeInput.value).replace(/\D/g, '').slice(0, 6);
    if (code.length !== 6) {
      showError('Enter the same code as relay.html.');
      return;
    }

    els.connectBtn.disabled = true;
    setStatus('waiting', 'Joining…');
    showError('');

    try {
      peer?.destroy();
      peer = await CasterSignaling.createPeerWithRetry(CasterSignaling.camPeerIdForCode(code));

      peer.on('connection', (conn) => {
        conn.on('data', async (msg) => {
          if (msg?.type === 'start-stream' && msg.desktopPeerId) await startStream(msg.desktopPeerId);
          if (msg?.type === 'stop-stream') stopStream();
        });
      });

      peer.on('error', (err) => {
        if (err.type === 'unavailable-id') showError('Code busy — refresh relay.html for a new code.');
      });

      els.codeDisplay.textContent = code;
      els.readyView.classList.remove('hidden');
      els.connectBtn.classList.add('hidden');
      els.codeInput.disabled = true;
      setStatus('connected', 'Ready — tap Live Stream on glasses');
    } catch (err) {
      showError(err.message || 'Could not join.');
      els.connectBtn.disabled = false;
      setStatus('waiting', 'Enter code from relay');
    }
  }

  els.connectBtn.addEventListener('click', joinSession);
  els.codeInput.addEventListener('keydown', (e) => { if (e.key === 'Enter') joinSession(); });
  els.codeInput.addEventListener('input', () => {
    els.codeInput.value = els.codeInput.value.replace(/\D/g, '').slice(0, 6);
  });

  const preset = new URLSearchParams(location.search).get('code');
  if (preset) {
    els.codeInput.value = preset.replace(/\D/g, '').slice(0, 6);
    joinSession();
  } else {
    setStatus('waiting', 'Enter code from relay');
  }
})();
