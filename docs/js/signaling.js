/**
 * PeerJS pairing + WebRTC — runs entirely from GitHub Pages.
 */

const APP_VERSION = '15';

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

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
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
  }), ms, 'Could not find phone relay. Keep relay.html open on your phone, then try again.');
}

function waitForRelayAck(conn, ms = 25000) {
  return withTimeout(new Promise((resolve, reject) => {
    function onData(msg) {
      if (msg?.type === 'relay-ack') {
        conn.off('data', onData);
        conn.off('close', onClose);
        resolve(msg);
      }
    }
    function onClose() {
      conn.off('data', onData);
      reject(new Error('Connection to phone relay closed.'));
    }
    conn.on('data', onData);
    conn.on('close', onClose);
  }), ms, 'Phone relay did not respond. Keep relay.html open and try again.');
}

function createPeer(id) {
  return new Peer(peerOptions(id));
}

async function createPeerWithRetry(id, attempts = 3) {
  let lastErr;
  for (let i = 0; i < attempts; i += 1) {
    const peer = createPeer(id);
    try {
      await waitForPeerOpen(peer, 15000);
      return peer;
    } catch (err) {
      lastErr = err;
      peer.destroy();
      if (i < attempts - 1) await sleep(500);
    }
  }
  throw lastErr || new Error('Could not join pairing network.');
}

async function connectToRelay(code, peer, role) {
  const relayId = peerIdForCode(code);
  const attempts = window.CASTER_CONFIG?.CONNECT_ATTEMPTS || 6;
  const timeoutMs = window.CASTER_CONFIG?.CONNECT_TIMEOUT_MS || 10000;
  const retryMs = window.CASTER_CONFIG?.CONNECT_RETRY_MS || 500;
  let lastErr;

  for (let i = 0; i < attempts; i += 1) {
    try {
      const conn = peer.connect(relayId, { reliable: true });
      await waitForConnection(conn, timeoutMs);
      sendData(conn, { type: 'hello', role, peerId: peer.id });
      await waitForRelayAck(conn, 8000);
      return conn;
    } catch (err) {
      lastErr = err;
      if (i < attempts - 1) await sleep(retryMs);
    }
  }

  throw lastErr || new Error('Could not find phone relay. Keep relay.html open on your phone.');
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
  connectToRelay,
  waitForPeerOpen,
  waitForConnection,
  waitForRelayAck,
  sendData,
};
