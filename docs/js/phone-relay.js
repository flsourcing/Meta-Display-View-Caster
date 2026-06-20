/**
 * Phone relay (web) — WebSocket signaling, for profile / home-screen install.
 */
(function () {
  const els = {
    pairCode: document.getElementById('pair-code'),
    codeTimer: document.getElementById('code-timer'),
    status: document.getElementById('status'),
    statusText: document.getElementById('status-text'),
    networkDot: document.getElementById('network-dot'),
    networkLabel: document.getElementById('network-label'),
    desktopLink: document.getElementById('desktop-link'),
  };

  let ws = null;
  let codeExpiresAt = 0;
  let timerInterval = null;

  function setStatus(kind, text) {
    els.status.className = `status ${kind}`;
    els.statusText.textContent = text;
  }

  function setOnline(online) {
    if (els.networkDot) els.networkDot.className = online ? 'network-dot online' : 'network-dot offline';
    if (els.networkLabel) els.networkLabel.textContent = online ? 'Relay online' : 'Relay offline';
  }

  function updateTimer() {
    const left = Math.max(0, Math.ceil((codeExpiresAt - Date.now()) / 1000));
    if (els.codeTimer) {
      els.codeTimer.textContent = left > 0 ? `Code expires in ${left}s` : 'Updating code…';
    }
  }

  function showCode(code) {
    if (els.pairCode) els.pairCode.textContent = code;
    if (els.desktopLink) els.desktopLink.href = `./?code=${code}`;
    codeExpiresAt = Date.now() + (window.CASTER_CONFIG?.CODE_ROTATION_MS || 300000);
    updateTimer();
  }

  async function start() {
    setStatus('waiting', 'Connecting to server…');
    try {
      ws = await CasterWS.connect();
      CasterWS.send(ws, { type: 'register-relay' });

      ws.addEventListener('message', async (ev) => {
        let msg;
        try { msg = JSON.parse(ev.data); } catch { return; }

        if (msg.type === 'relay-registered' || msg.type === 'code-rotated') {
          showCode(msg.code);
          setOnline(true);
          setStatus('waiting', 'Ready — connect desktop & glasses');
        }
        if (msg.type === 'desktop-joined') setStatus('connected', 'Desktop connected');
        if (msg.type === 'glasses-joined') setStatus('connected', 'Glasses connected');
        if (msg.type === 'start-stream') {
          setStatus('waiting', 'Starting camera…');
          await CasterWebRTCPhone.startStream(ws);
          setStatus('connected', 'Streaming');
        }
        if (msg.type === 'stop-stream') {
          CasterWebRTCPhone.stopStream();
          setStatus('connected', 'Ready');
        }
        if (msg.type === 'answer') await CasterWebRTCPhone.handleAnswer(msg);
        if (msg.type === 'ice-candidate') await CasterWebRTCPhone.handleRemoteIce(msg);
      });

      ws.addEventListener('close', () => {
        setOnline(false);
        setStatus('error', 'Disconnected — reopen app');
      });
    } catch (err) {
      setOnline(false);
      setStatus('error', err.message || 'Could not connect');
    }
  }

  async function requestWakeLock() {
    try {
      if ('wakeLock' in navigator) await navigator.wakeLock.request('screen');
    } catch { /* optional */ }
  }

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') requestWakeLock();
  });

  if (!timerInterval) timerInterval = setInterval(updateTimer, 1000);
  requestWakeLock();
  start();
})();
