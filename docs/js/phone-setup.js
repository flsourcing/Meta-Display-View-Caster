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

  let metaOpenedAt = 0;

  function glassesUrl() {
    return window.CasterMetaAI?.glassesAppUrl?.() || `${location.href.replace(/[^/?#]*([?#].*)?$/, '')}glasses.html`;
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
    setStepStatus(els.cameraStatus, 'Tap the button below — iOS will ask to allow camera access.');
  }

  function finishCamera() {
    localStorage.setItem(STORAGE.camera, '1');
    showReady();
  }

  async function allowCamera() {
    if (!navigator.mediaDevices?.getUserMedia) {
      setStepStatus(els.cameraStatus, 'Camera not available in this browser.', false);
      return;
    }

    els.cameraBtn.disabled = true;
    setStepStatus(els.cameraStatus, 'Allow camera when iOS asks…');

    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        video: { facingMode: 'environment', width: { ideal: 1280 }, height: { ideal: 720 } },
        audio: false,
      });
      stream.getTracks().forEach((t) => t.stop());
      setStepStatus(els.cameraStatus, 'Camera allowed — ready for Live Stream.', true);
      finishCamera();
    } catch {
      setStepStatus(
        els.cameraStatus,
        'Camera denied. Settings → View Caster → Camera → Allow, then tap again.',
        false
      );
    } finally {
      els.cameraBtn.disabled = false;
    }
  }

  function openMetaForCamera() {
    metaOpenedAt = Date.now();
    setStepStatus(els.cameraStatus, 'Opening Meta AI… check glasses permissions if needed.', null);
    try {
      window.CasterMetaAI.openMetaAi();
    } catch {
      setStepStatus(els.cameraStatus, 'Install Meta AI from the App Store, then try again.', false);
    }
  }

  function resetSetup() {
    localStorage.removeItem(STORAGE.meta);
    localStorage.removeItem(STORAGE.camera);
    location.reload();
  }

  function init() {
    if (els.glassesUrl) els.glassesUrl.textContent = glassesUrl();

    if (els.metaBtn && window.CasterMetaAI) {
      els.metaBtn.href = window.CasterMetaAI.webAppDeepLink(
        window.CasterMetaAI.glassesAppName(),
        glassesUrl()
      );
      els.metaBtn.addEventListener('click', () => {
        metaOpenedAt = Date.now();
        setStepStatus(els.metaStatus, 'Opening Meta AI… approve Connect when prompted.', null);
        window.setTimeout(() => {
          if (document.visibilityState === 'visible' && Date.now() - metaOpenedAt < 3000) {
            setStepStatus(
              els.metaStatus,
              'If Meta AI did not open: install Meta AI from the App Store, then tap again.',
              false
            );
          }
        }, 2500);
      });
    }
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
      if (metaOpenedAt && Date.now() - metaOpenedAt < 120000) {
        if (!isMetaDone() && els.stepMeta && !els.stepMeta.classList.contains('hidden')) {
          setStepStatus(
            els.metaStatus,
            'Back from Meta AI? If you tapped Connect, tap Continue below.',
            true
          );
        }
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
