/**
 * GitHub Pages UI + optional WebSocket signaling for native phone app.
 */
window.CASTER_CONFIG = {
  PEER_PREFIX: 'mdvc-',
  CAM_PREFIX: 'mdvc-cam-',
  CODE_ROTATION_MS: 300_000,
  CONNECT_TIMEOUT_MS: 7000,
  CONNECT_RETRY_MS: 400,
  CONNECT_ATTEMPTS: 6,
  CONNECT_TOTAL_MS: 22000,

  // Set after deploying server/ to Render (or your host). Example:
  // SIGNALING_URL: 'wss://meta-display-view-caster.onrender.com',
  SIGNALING_URL: 'wss://meta-display-view-caster.onrender.com',

  PEERJS: {
    host: '0.peerjs.com',
    port: 443,
    path: '/',
    secure: true,
    key: 'peerjs',
  },

  ICE_SERVERS: [
    { urls: 'stun:stun.l.google.com:19302' },
    { urls: 'stun:stun1.l.google.com:19302' },
    {
      urls: 'turn:openrelay.metered.ca:80',
      username: 'openrelayproject',
      credential: 'openrelayproject',
    },
    {
      urls: 'turn:openrelay.metered.ca:443',
      username: 'openrelayproject',
      credential: 'openrelayproject',
    },
    {
      urls: ['turn:eu-0.turn.peerjs.com:3478', 'turn:us-0.turn.peerjs.com:3478'],
      username: 'peerjs',
      credential: 'peerjsp',
    },
  ],
};
