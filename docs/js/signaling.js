/**
 * PeerJS pairing + WebRTC — runs entirely from GitHub Pages.
 */

const APP_VERSION = '8';

function generateCode() {
  return String(Math.floor(100000 + Math.random() * 900000));
}

function peerIdForCode(code) {
  return `${window.CASTER_CONFIG?.PEER_PREFIX || 'mdvc-'}${code}`;
}

function camPeerIdForCode(code) {
  return `${window.CASTER_CONFIG?.CAM_PREFIX || 'mdvc-cam-'}${code}`;
}

function hasCameraSupport() {
  return !!(navigator.mediaDevices?.getUserMedia);
}

function peerOptions(id) {
  const cfg = window.CASTER_CONFIG?.PEERJS || {};
  const opts = {
    host: cfg.host || '0.peerjs.com',
    port: cfg.port || 443,
    path: cfg.path || '/',
    secure: cfg.secure !== false,
    key: cfg.key || 'peerjs',
    config: { iceServers: window.CASTER_CONFIG?.ICE_SERVERS || [{ urls: 'stun:stun.l.google.com:19302' }] },
  };
  if (id) opts.id = id;
  return opts;
}

function withTimeout(promise, ms, message) {
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error(message)), ms);
    promise.then((v) => { clearTimeout(t); resolve(v); }).catch((e) => { clearTimeout(t); reject(e); });
  });
}

function waitForPeerOpen(peer, ms = 25000) {
  if (peer.destroyed) return Promise.reject(new Error('Peer closed.'));
  if (peer.open) return Promise.resolve(peer);
  return withTimeout(new Promise((res, rej) => {
    peer.once('open', () => res(peer));
    peer.once('error', rej);
  }), ms, 'Could not reach pairing network. Check internet and try again.');
}

function waitForConnection(conn, ms = 30000) {
  if (conn.open) return Promise.resolve(conn);
  return withTimeout(new Promise((res, rej) => {
    conn.once('open', () => res(conn));
    conn.once('error', rej);
    conn.once('close', () => rej(new Error('Connection closed.')));
  }), ms, 'Could not find that code. Open relay.html on your phone, copy the code shown, and try again right away.');
}

function createPeer(id) {
  return new Peer(peerOptions(id));
}

async function createPeerWithRetry(id, attempts = 3) {
  let lastErr;
  for (let i = 0; i < attempts; i += 1) {
    const peer = createPeer(id);
    try {
      await waitForPeerOpen(peer);
      return peer;
    } catch (err) {
      lastErr = err;
      peer.destroy();
      if (err.type === 'unavailable-id' || err.type === 'network') {
        await new Promise((r) => setTimeout(r, 1000));
      }
    }
  }
  throw lastErr || new Error('Could not join pairing network.');
}

function sendData(conn, data) {
  if (conn?.open) conn.send(data);
}

window.CasterSignaling = {
  APP_VERSION,
  generateCode,
  peerIdForCode,
  camPeerIdForCode,
  hasCameraSupport,
  createPeer,
  createPeerWithRetry,
  waitForPeerOpen,
  waitForConnection,
  sendData,
};
