/**
 * GitHub Pages UI — PeerJS relay by default (no server deploy required).
 * Optional: deploy server/ to Render and set SIGNALING_URL for native app + WS mode.
 */
window.CASTER_CONFIG = {
  PEER_PREFIX: 'mdvc-',
  CAM_PREFIX: 'mdvc-cam-',
  CODE_ROTATION_MS: 300_000,
  CONNECT_TIMEOUT_MS: 10000,
  CONNECT_RETRY_MS: 500,
  CONNECT_ATTEMPTS: 8,
  CONNECT_TOTAL_MS: 45000,

  // Leave empty for profile / Safari relay (PeerJS). After deploying server/ to Render:
  // SIGNALING_URL: 'wss://YOUR-SERVICE.onrender.com',
  SIGNALING_URL: '',

  GLASSES_APP_URL: 'https://flsourcing.github.io/Meta-Display-View-Caster/glasses.html',
  GLASSES_APP_NAME: 'ViewCaster',

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
