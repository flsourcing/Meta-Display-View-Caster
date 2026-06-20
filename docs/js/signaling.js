/**
 * Client-side pairing + WebRTC via PeerJS (no custom server — works on GitHub Pages).
 */

const APP_VERSION = '3';

function generateCode() {
  return String(Math.floor(100000 + Math.random() * 900000));
}

function peerIdForCode(code) {
  const prefix = window.CASTER_CONFIG?.PEER_PREFIX || 'mdvc-';
  return `${prefix}${code}`;
}

function createPeerOptions(id) {
  const cfg = window.CASTER_CONFIG || {};
  const options = {
    host: cfg.PEER_HOST || '0.peerjs.com',
    port: cfg.PEER_PORT || 443,
    path: cfg.PEER_PATH || '/',
    secure: cfg.PEER_SECURE !== false,
    debug: cfg.PEER_DEBUG || 1,
    config: {
      iceServers: cfg.ICE_SERVERS || [
        { urls: 'stun:stun.l.google.com:19302' },
        {
          urls: 'turn:openrelay.metered.ca:80',
          username: 'openrelayproject',
          credential: 'openrelayproject',
        },
      ],
    },
  };
  if (id) options.id = id;
  return options;
}

function withTimeout(promise, ms, message) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      reject(new Error(message || `Timed out after ${ms / 1000}s`));
    }, ms);
    promise
      .then((value) => {
        clearTimeout(timer);
        resolve(value);
      })
      .catch((err) => {
        clearTimeout(timer);
        reject(err);
      });
  });
}

function waitForPeerOpen(peer, timeoutMs = 15000) {
  if (peer.destroyed) {
    return Promise.reject(new Error('Peer was destroyed before it could connect.'));
  }
  if (peer.open) return Promise.resolve(peer);

  return withTimeout(
    new Promise((resolve, reject) => {
      peer.once('open', () => resolve(peer));
      peer.once('error', reject);
      peer.once('close', () => reject(new Error('Peer closed before connecting to the network.')));
    }),
    timeoutMs,
    'Could not reach the pairing network. Check your internet connection and try again.',
  );
}

function waitForConnection(conn, timeoutMs = 15000) {
  if (conn.open) return Promise.resolve(conn);

  return withTimeout(
    new Promise((resolve, reject) => {
      conn.once('open', () => resolve(conn));
      conn.once('error', reject);
      conn.once('close', () => reject(new Error('Connection closed before pairing completed.')));
    }),
    timeoutMs,
    'Glasses not found. Open glasses.html, wait for the code to appear, then enter the current code.',
  );
}

function sendData(conn, payload) {
  if (conn?.open) {
    conn.send(payload);
  }
}

function createPeer(id) {
  return new Peer(createPeerOptions(id));
}

window.CasterSignaling = {
  APP_VERSION,
  generateCode,
  peerIdForCode,
  createPeerOptions,
  createPeer,
  withTimeout,
  waitForPeerOpen,
  waitForConnection,
  sendData,
};
