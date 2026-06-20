/**
 * Phone profile app — permissions, Meta AI setup, relay restart.
 */
(function () {
  const permBtn = document.getElementById('perm-btn');
  const metaBtn = document.getElementById('meta-btn');
  const restartBtn = document.getElementById('restart-btn');
  const permStatus = document.getElementById('perm-status');
  const metaPanel = document.getElementById('meta-panel');
  const glassesUrlEl = document.getElementById('glasses-url');
  const networkLabel = document.getElementById('network-label');

  function pageBase() {
    return location.href.replace(/[^/]*$/, '');
  }

  function glassesUrl() {
    return `${pageBase()}glasses.html`;
  }

  function setPermStatus(text, ok) {
    if (!permStatus) return;
    permStatus.textContent = text;
    permStatus.style.color = ok === true ? 'var(--success)' : ok === false ? 'var(--error)' : 'var(--muted)';
  }

  async function allowPermissions() {
    if (!navigator.mediaDevices?.getUserMedia) {
      setPermStatus('Camera API not available in this browser.', false);
      return;
    }
    setPermStatus('Requesting camera access…');
    permBtn.disabled = true;
    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        video: { facingMode: 'environment', width: { ideal: 1280 }, height: { ideal: 720 } },
        audio: false,
      });
      stream.getTracks().forEach((t) => t.stop());
      setPermStatus('Camera allowed. You can stream when glasses tap Live Stream.', true);
    } catch {
      setPermStatus(
        'Camera denied. iOS: Settings → View Caster (or Safari) → Camera → Allow.',
        false
      );
    } finally {
      permBtn.disabled = false;
    }
  }

  async function copyText(text) {
    try {
      await navigator.clipboard.writeText(text);
      return true;
    } catch {
      try {
        const ta = document.createElement('textarea');
        ta.value = text;
        ta.style.position = 'fixed';
        ta.style.opacity = '0';
        document.body.appendChild(ta);
        ta.select();
        document.execCommand('copy');
        document.body.removeChild(ta);
        return true;
      } catch {
        return false;
      }
    }
  }

  async function connectMetaAi() {
    const url = glassesUrl();
    if (glassesUrlEl) glassesUrlEl.textContent = url;
    if (metaPanel) metaPanel.classList.remove('hidden');
    const copied = await copyText(url);
    setPermStatus(
      copied
        ? 'Glasses URL copied — paste it in Meta AI → Web apps.'
        : 'Copy the URL below into Meta AI → Web apps.',
      copied
    );
    metaPanel?.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
  }

  function restartRelay() {
    location.reload();
  }

  permBtn?.addEventListener('click', allowPermissions);
  metaBtn?.addEventListener('click', connectMetaAi);
  restartBtn?.addEventListener('click', restartRelay);

  const dot = document.getElementById('network-dot');
  if (dot && networkLabel) {
    const observer = new MutationObserver(() => {
      const online = dot.classList.contains('online');
      networkLabel.textContent = online ? 'Relay online' : 'Relay offline';
    });
    observer.observe(dot, { attributes: true, attributeFilter: ['class'] });
  }

  if (glassesUrlEl) glassesUrlEl.textContent = glassesUrl();
})();
