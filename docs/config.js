/**
 * Meta Display View Caster — config
 */
window.CASTER_CONFIG = {
  // WebSocket signaling server (Render — see README to deploy)
  SIGNALING_URL: 'wss://meta-display-view-caster.onrender.com',

  CODE_ROTATION_MS: 180_000,

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
