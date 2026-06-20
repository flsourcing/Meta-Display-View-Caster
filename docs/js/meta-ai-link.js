/**
 * Meta AI deep links for adding MRBD web apps (official format from Meta wearables toolkit).
 */
(function () {
  const DEFAULT_GLASSES_URL = 'https://flsourcing.github.io/Meta-Display-View-Caster/glasses.html';
  const DEFAULT_APP_NAME = 'ViewCaster';

  function glassesAppUrl() {
    return window.CASTER_CONFIG?.GLASSES_APP_URL || DEFAULT_GLASSES_URL;
  }

  function glassesAppName() {
    return window.CASTER_CONFIG?.GLASSES_APP_NAME || DEFAULT_APP_NAME;
  }

  function webAppDeepLink(appName, appUrl) {
    const params = new URLSearchParams({
      appName: appName || glassesAppName(),
      appUrl: appUrl || glassesAppUrl(),
    });
    return `fb-viewapp://web_app_deep_link?${params.toString()}`;
  }

  function openAppLink(url) {
    const iframe = document.createElement('iframe');
    iframe.style.display = 'none';
    iframe.src = url;
    document.body.appendChild(iframe);
    window.setTimeout(() => iframe.remove(), 2000);

    const a = document.createElement('a');
    a.href = url;
    a.style.display = 'none';
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
  }

  function openMetaAi() {
    openAppLink('fb-viewapp://');
  }

  function openAddWebApp(appName, appUrl) {
    openAppLink(webAppDeepLink(appName, appUrl));
  }

  window.CasterMetaAI = {
    glassesAppUrl,
    glassesAppName,
    webAppDeepLink,
    openMetaAi,
    openAddWebApp,
  };
})();
