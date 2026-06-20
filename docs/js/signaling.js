/**
 * Client-side pairing + WebRTC via PeerJS (no custom server — works on GitHub Pages).
 */

function generateCode() {
  return String(Math.floor(100000 + Math.random() * 900000));
}

function peerIdForCode(code) {
  const prefix = window.CASTER_CONFIG?.PEER_PREFIX || 'mdvc-';
  return `${prefix}${code}`;
}

function createPeerOptions() {
  return {
    config: {
      iceServers: window.CASTER_CONFIG?.ICE_SERVERS || [
        { urls: 'stun:stun.l.google.com:19302' },
      ],
    },
  };
}

function waitForPeerOpen(peer) {
  return new Promise((resolve, reject) => {
    if (peer.open) {
      resolve(peer);
      return;
    }
    peer.once('open', () => resolve(peer));
    peer.once('error', reject);
  });
}

function waitForConnection(conn) {
  return new Promise((resolve, reject) => {
    if (conn.open) {
      resolve(conn);
      return;
    }
    conn.once('open', () => resolve(conn));
    conn.once('error', reject);
  });
}

function sendData(conn, payload) {
  if (conn?.open) {
    conn.send(payload);
  }
}

window.CasterSignaling = {
  generateCode,
  peerIdForCode,
  createPeerOptions,
  waitForPeerOpen,
  waitForConnection,
  sendData,
};
