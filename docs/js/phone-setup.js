/**
 * Phone profile app — first-run setup wizard, then relay dashboard.
 */
(function () {
  const STORAGE = {
    meta: 'mdvc_setup_meta',
    camera: 'mdvc_setup_camera',
  };

  const els = {
    setupView: document.getElementById('setup-view'),
    readyView: document.getElementById('ready-view'),
    stepMeta: document.getElementById('step-meta'),
    stepCamera: document.getElementById('step-camera'),
    metaBtn: document.getElementById('meta-connect-btn'),
    metaDoneBtn: document.getElementById('meta-done-btn'),
    metaStatus: document.getElementById('meta-status'),
    glassesUrl: document.getElementById('glasses-url'),
    cameraBtn: document.getElementById('camera-connect-btn'),
    cameraMetaBtn: document.getElementById('camera-meta-btn'),
    cameraStatus: document.getElementById('camera-status'),
    restartBtn: document.getElementById('restart-btn'),
    resetSetupBtn: document.getElementById('reset-setup-btn'),
    networkLabel: document.getElementById('network-label'),
  };

  function pageBase() {
    return location.href.replace(/[^/?#]*([?#].*)?$/, '');
  }

  function glassesUrl() {
    return `${pageBase()}glasses.html`;
  }

  function isMetaDone() {
    return localStorage.getItem(STORAGE.meta) === '1';
  }

  function isCameraDone() {
    return localStorage.getItem(STORAGE.camera) === '1';
  }

  function isSetupComplete() {
    return isMetaDone() && isCameraDone();
  }

  function setStepStatus(el, text, ok) {
    if (!el) return;
    el.textContent = text;
    el.style.color = ok === true ? 'var(--success)' : ok === false ? 'var(--error)' : 'var(--muted)';
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

  function showStep(step) {
    els.stepMeta?.classList.toggle('hidden', step !== 'meta');
    els.stepCamera?.classList.toggle('hidden', step !== 'camera');
  }

  function showReady() {
    els.setupView?.classList.add('hidden');
    els.readyView?.classList.remove('hidden');
    if (window.CasterRelay?.start) window.CasterRelay.start();
    else if (window.CasterRelay?.restart) window.CasterRelay.restart();
  }

  function showSetup(step) {
    els.setupView?.classList.remove('hidden');
    els.readyView?.classList.add('hidden');
    showStep(step);
  }

  function finishMeta() {
    localStorage.setItem(STORAGE.meta, '1');
    showStep('camera');
    setStepStatus(els.cameraStatus, 'Allow camera so Live Stream can cast to your desktop.');
  }

  function finishCamera() {
    localStorage.setItem(STORAGE.camera, '1');
    showReady();
  }

  function openMetaAiApp() {
    const url = glassesUrl();
    copyText(url);

    const schemes = [
      'metaai://',
      'meta-ai://',
    ];

    let opened = false;
    for (const scheme of schemes) {
      try {
        window.location.href = scheme;
        opened = true;
        break;
      } catch {
        /* try next */
      }
    }

    setStepStatus(
      els.metaStatus,
      opened
        ? 'Opening Meta AI… Add the glasses web app (URL copied).'
        : 'Copy the URL below and add it in Meta AI → Web apps.',
      null
    );

    if (els.glassesUrl) els.glassesUrl.textContent = url;
  }

  async function allowCamera() {
    if (!navigator.mediaDevices?.getUserMedia) {
      setStepStatus(els.cameraStatus, 'Camera not available in this browser.', false);
      return;
    }

    els.cameraBtn.disabled = true;
    setStepStatus(els.cameraStatus, 'Requesting camera access…');

    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        video: { facingMode: 'environment', width: { ideal: 1280 }, height: { ideal: 720 } },
        audio: false,
      });
      stream.getTracks().forEach((t) => t.stop());
      setStepStatus(els.cameraStatus, 'Camera ready for live streaming.', true);
      finishCamera();
    } catch {
      setStepStatus(
        els.cameraStatus,
        'Camera denied. iOS: Settings → View Caster → Camera → Allow, then tap again.',
        false
      );
    } finally {
      els.cameraBtn.disabled = false;
    }
  }

  function openMetaForCamera() {
    openMetaAiApp();
    setStepStatus(
      els.cameraStatus,
      'In Meta AI: Devices → your glasses → ensure camera / live view permissions are on. Then tap Allow camera below.',
      null
    );
  }

  function resetSetup() {
    localStorage.removeItem(STORAGE.meta);
    localStorage.removeItem(STORAGE.camera);
    location.reload();
  }

  function init() {
    if (els.glassesUrl) els.glassesUrl.textContent = glassesUrl();

    els.metaBtn?.addEventListener('click', openMetaAiApp);
    els.metaDoneBtn?.addEventListener('click', finishMeta);
    els.cameraBtn?.addEventListener('click', allowCamera);
    els.cameraMetaBtn?.addEventListener('click', openMetaForCamera);
    els.restartBtn?.addEventListener('click', () => {
      if (window.CasterRelay?.restart) window.CasterRelay.restart();
      else location.reload();
    });
    els.resetSetupBtn?.addEventListener('click', resetSetup);

    const dot = document.getElementById('network-dot');
    if (dot && els.networkLabel) {
      const observer = new MutationObserver(() => {
        const online = dot.classList.contains('online');
        els.networkLabel.textContent = online ? 'Relay online' : 'Relay offline';
      });
      observer.observe(dot, { attributes: true, attributeFilter: ['class'] });
    }

    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState !== 'visible') return;
      if (!isMetaDone() && els.stepMeta && !els.stepMeta.classList.contains('hidden')) {
        setStepStatus(els.metaStatus, 'Welcome back — tap “I added View Caster on glasses” when done.');
      }
    });

    if (isSetupComplete()) {
      showReady();
    } else if (isMetaDone()) {
      showSetup('camera');
    } else {
      showSetup('meta');
    }
  }

  init();
})();
