/**
 * Phone relay — shows pairing code only (desktop hosts the session).
 * Keep this page open so you can read the code; switching apps is OK now.
 */
(function () {
  const els = {
    pairCode: document.getElementById('pair-code'),
    codeTimer: document.getElementById('code-timer'),
    status: document.getElementById('status'),
    statusText: document.getElementById('status-text'),
    keepOpenHint: document.getElementById('keep-open-hint'),
    desktopLink: document.getElementById('desktop-link'),
    captureLink: document.getElementById('capture-link'),
  };

  const ROTATION_MS = window.CASTER_CONFIG?.CODE_ROTATION_MS || 300_000;

  let currentCode = '';
  let codeExpiresAt = 0;
  let timerInterval = null;
  let rotationTimeout = null;

  function setStatus(kind, text) {
    els.status.className = `status ${kind}`;
    els.statusText.textContent = text;
  }

  function updateTimer() {
    const left = Math.max(0, Math.ceil((codeExpiresAt - Date.now()) / 1000));
    els.codeTimer.textContent = left > 0 ? `Code expires in ${left}s` : 'Updating code…';
  }

  function pageBase() {
    return location.href.replace(/[^/]*$/, '');
  }

  function showCode(code) {
    currentCode = code;
    els.pairCode.textContent = code;
    codeExpiresAt = Date.now() + ROTATION_MS;
    updateTimer();

    const base = pageBase();
    if (els.desktopLink) {
      els.desktopLink.href = `${base}?code=${code}`;
    }
    if (els.captureLink) {
      els.captureLink.href = `${base}capture.html?code=${code}`;
    }
  }

  function rotateCode() {
    showCode(CasterSignaling.generateCode());
    setStatus('waiting', 'Enter this code on desktop, then glasses');
    clearTimeout(rotationTimeout);
    rotationTimeout = setTimeout(rotateCode, ROTATION_MS);
  }

  if (!timerInterval) timerInterval = setInterval(updateTimer, 1000);

  if (els.keepOpenHint) {
    els.keepOpenHint.textContent = 'Step 1: enter this code on desktop and tap Connect. Step 2: same code on glasses.';
    els.keepOpenHint.classList.remove('error');
  }

  rotateCode();
})();
