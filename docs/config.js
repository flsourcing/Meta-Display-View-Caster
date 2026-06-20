/**
 * Meta Display View Caster — client-side config (GitHub Pages only, no backend).
 */
window.CASTER_CONFIG = {
  PEER_PREFIX: 'mdvc-',
  CAM_PREFIX: 'mdvc-cam-',
  CODE_ROTATION_MS: 180_000,

  // PeerJS signaling — try each host in order until one connects
  PEER_HOSTS: [
    { host: '0.peerjs.com', port: 443, path: '/', secure: true, key: 'peerjs' },
  ],

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
