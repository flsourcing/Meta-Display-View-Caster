/**
 * Phone camera bridge — streams to desktop when Meta Display has no camera API.
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
  let dataConn = null;
  let localStream = null;
  let activeCall = null;
  let currentCode = '';
  let ready = false;
  let streaming = false;

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
    streaming = false;
    if (ready) setStatus('connected', 'Ready — tap Live Stream on glasses');
  }

  async function startStream(desktopPeerId) {
    stopStream();
    setStatus('waiting', 'Starting camera…');

    try {
      localStream = await navigator.mediaDevices.getUserMedia({
        video: { facingMode: 'environment', width: { ideal: 1280 }, height: { ideal: 720 } },
        audio: false,
      });
    } catch (err) {
      console.error('[caster] phone camera failed:', err);
      CasterSignaling.sendData(dataConn, {
        type: 'stream-error',
        message: 'Allow camera access on your phone and try again.',
      });
      setStatus('error', 'Camera permission denied');
      return;
    }

    activeCall = peer.call(desktopPeerId, localStream);
    activeCall.on('close', stopStream);
    streaming = true;
    setStatus('connected', 'Live stream active');
    CasterSignaling.sendData(dataConn, { type: 'stream-started' });
  }

  async function joinSession() {
    const params = new URLSearchParams(location.search);
    const code = (params.get('code') || els.codeInput.value).replace(/\D/g, '').slice(0, 6);

    if (code.length !== 6) {
      showError('Enter the same 6-digit code shown on your glasses.');
      return;
    }

    showError('');
    els.connectBtn.disabled = true;
    setStatus('waiting', 'Joining…');

    try {
      peer?.destroy();
      currentCode = code;
      peer = await CasterSignaling.createPeerWithFallback(CasterSignaling.camPeerIdForCode(code));

      peer.on('connection', (conn) => {
        dataConn = conn;

        conn.on('data', async (msg) => {
          if (msg?.type === 'start-stream' && msg.desktopPeerId) {
            await startStream(msg.desktopPeerId);
          } else if (msg?.type === 'stop-stream') {
            stopStream();
          }
        });

        conn.on('close', () => {
          stopStream();
          if (ready) setStatus('connected', 'Ready — tap Live Stream on glasses');
        });
      });

      peer.on('error', (err) => {
        if (err.type === 'unavailable-id') {
          showError('Session busy. Use the current code from your glasses.');
        } else {
          console.error('[caster] capture peer error:', err);
        }
        els.connectBtn.disabled = false;
      });

      ready = true;
      els.codeDisplay.textContent = code;
      els.readyView.classList.remove('hidden');
      els.connectBtn.classList.add('hidden');
      els.codeInput.disabled = true;
      setStatus('connected', 'Ready — tap Live Stream on glasses');
      showError('');
    } catch (err) {
      console.error('[caster] capture join failed:', err);
      showError(err.message || 'Could not join. Check the code and try again.');
      els.connectBtn.disabled = false;
      setStatus('waiting', 'Enter code from glasses');
      peer?.destroy();
      peer = null;
    }
  }

  els.connectBtn.addEventListener('click', joinSession);
  els.codeInput.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') joinSession();
  });
  els.codeInput.addEventListener('input', () => {
    els.codeInput.value = els.codeInput.value.replace(/\D/g, '').slice(0, 6);
  });

  const presetCode = new URLSearchParams(location.search).get('code');
  if (presetCode) {
    els.codeInput.value = presetCode.replace(/\D/g, '').slice(0, 6);
    joinSession();
  } else {
    setStatus('waiting', 'Enter code from glasses');
  }
})();
