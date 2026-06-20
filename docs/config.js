/**
 * Meta Display View Caster — client-side config (GitHub Pages only, no backend).
 */
window.CASTER_CONFIG = {
  // Prefix for PeerJS room IDs (keeps IDs unique on the public PeerJS cloud)
  PEER_PREFIX: 'mdvc-',

  // Pairing code rotates every 60 seconds for privacy
  CODE_ROTATION_MS: 60_000,

  // STUN servers for WebRTC NAT traversal
  ICE_SERVERS: [
    { urls: 'stun:stun.l.google.com:19302' },
    { urls: 'stun:stun1.l.google.com:19302' },
  ],
};
