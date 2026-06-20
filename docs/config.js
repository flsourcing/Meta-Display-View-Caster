/**
 * Meta Display View Caster — client-side config (GitHub Pages only, no backend).
 */
window.CASTER_CONFIG = {
  PEER_PREFIX: 'mdvc-',
  CAM_PREFIX: 'mdvc-cam-',
  CODE_ROTATION_MS: 60_000,

  // PeerJS public cloud (handles pairing signaling in the browser)
  PEER_HOST: '0.peerjs.com',
  PEER_PORT: 443,
  PEER_PATH: '/',
  PEER_SECURE: true,

  ICE_SERVERS: [
    { urls: 'stun:stun.l.google.com:19302' },
    { urls: 'stun:stun1.l.google.com:19302' },
    {
      urls: 'turn:openrelay.metered.ca:80',
      username: 'openrelayproject',
      credential: 'openrelayproject',
    },
  ],
};
