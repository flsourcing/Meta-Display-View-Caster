/**
 * Client-side pairing + WebRTC via PeerJS (no custom server — works on GitHub Pages).
 */

const APP_VERSION = '6';

function generateCode() {
  return String(Math.floor(100000 + Math.random() * 900000));
}

function peerIdForCode(code) {
  const prefix = window.CASTER_CONFIG?.PEER_PREFIX || 'mdvc-';
  return `${prefix}${code}`;
}

function camPeerIdForCode(code) {
  const prefix = window.CASTER_CONFIG?.CAM_PREFIX || 'mdvc-cam-';
  return `${prefix}${code}`;
}

function hasCameraSupport() {
  return !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia);
}

function getPeerHosts() {
  const cfg = window.CASTER_CONFIG || {};
  if (cfg.PEER_HOSTS?.length) return cfg.PEER_HOSTS;
  return [{
    host: cfg.PEER_HOST || '0.peerjs.com',
    port: cfg.PEER_PORT || 443,
    path: cfg.PEER_PATH || '/',
    secure: cfg.PEER_SECURE !== false,
    key: cfg.PEER_KEY || 'peerjs',
  }];
}

function createPeerOptions(id, hostIndex = 0) {
  const hosts = getPeerHosts();
  const server = hosts[hostIndex] || hosts[0];
  const options = {
    host: server.host,
    port: server.port,
    path: server.path,
    secure: server.secure !== false,
    key: server.key || 'peerjs',
    debug: 2,
    config: {
      iceServers: window.CASTER_CONFIG?.ICE_SERVERS || [
        { urls: 'stun:stun.l.google.com:19302' },
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

function waitForPeerOpen(peer, timeoutMs = 20000) {
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

function waitForConnection(conn, timeoutMs = 30000) {
  if (conn.open) return Promise.resolve(conn);

  return withTimeout(
    new Promise((resolve, reject) => {
      conn.once('open', () => resolve(conn));
      conn.once('error', reject);
      conn.once('close', () => reject(new Error('Connection closed before pairing completed.')));
    }),
    timeoutMs,
    'Could not find glasses with that code. Make sure glasses.html is open, the code matches exactly, and try again immediately.',
  );
}

function sendData(conn, payload) {
  if (conn?.open) {
    conn.send(payload);
  }
}

function createPeer(id, hostIndex = 0) {
  return new Peer(createPeerOptions(id, hostIndex));
}

async function createPeerWithFallback(id) {
  const hosts = getPeerHosts();
  let lastError;

  for (let i = 0; i < hosts.length; i += 1) {
    const peer = createPeer(id, i);
    try {
      await waitForPeerOpen(peer);
      return peer;
    } catch (err) {
      lastError = err;
      peer.destroy();
    }
  }

  throw lastError || new Error('Could not connect to the pairing network.');
}

window.CasterSignaling = {
  APP_VERSION,
  generateCode,
  peerIdForCode,
  camPeerIdForCode,
  hasCameraSupport,
  createPeerOptions,
  createPeer,
  createPeerWithFallback,
  withTimeout,
  waitForPeerOpen,
  waitForConnection,
  sendData,
};
