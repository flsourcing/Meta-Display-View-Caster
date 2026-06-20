/**
 * Signaling server URL.
 * After deploying the server (see README), set this to your public WebSocket endpoint.
 * Example: wss://meta-display-view-caster.onrender.com
 */
window.CASTER_CONFIG = {
  // Replace with your deployed signaling server URL (no trailing slash)
  SIGNALING_URL: 'wss://meta-display-view-caster.onrender.com',

  // STUN servers for WebRTC NAT traversal
  ICE_SERVERS: [
    { urls: 'stun:stun.l.google.com:19302' },
    { urls: 'stun:stun1.l.google.com:19302' },
  ],
};
