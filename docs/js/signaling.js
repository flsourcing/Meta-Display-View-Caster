/**
 * PeerJS pairing + WebRTC — runs entirely from GitHub Pages.
 */

const APP_VERSION = '24';

function generateCode() {
  return String(Math.floor(100000 + Math.random() * 900000));
}

function peerIdForCode(code) {
  return `${window.CASTER_CONFIG?.PEER_PREFIX || 'mdvc-'}${code}`;
}

function desktopPeerIdForCode(code) {
  return `${window.CASTER_CONFIG?.PEER_PREFIX || 'mdvc-'}desktop-${code}`;
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
  }), ms, 'Could not reach phone relay. Keep the View Caster phone app open with a green dot.');
}

function connectAny(promises) {
  return new Promise((resolve, reject) => {
    if (!promises?.length) {
      reject(new Error('No connection attempts.'));
      return;
    }
    let pending = promises.length;
    let lastErr;
    promises.forEach((p) => {
      Promise.resolve(p).then(resolve).catch((err) => {
        lastErr = err;
        pending -= 1;
        if (pending === 0) reject(lastErr);
      });
    });
  });
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
  }), ms, 'Phone relay did not respond. Reopen the View Caster app on your phone.');
}

function waitForIncomingHello(peer, role, ms = 35000) {
  return withTimeout(new Promise((resolve, reject) => {
    function onConnection(conn) {
      function onData(msg) {
        if (msg?.type === 'hello' && msg.role === role) {
          peer.off('connection', onConnection);
          conn.off('data', onData);
          conn.off('close', onClose);
          sendData(conn, { type: 'relay-ack', role: 'desktop' });
          resolve(conn);
        }
      }
      function onClose() {
        conn.off('data', onData);
      }
      conn.on('data', onData);
      conn.on('close', onClose);
    }
    peer.on('connection', onConnection);
  }), ms, 'Phone relay did not connect. Keep the View Caster app open with a green dot, then try again.');
}

async function createNamedPeerWithRetry(id, attempts = 4) {
  let lastErr;
  for (let i = 0; i < attempts; i += 1) {
    const peer = createPeer(id);
    try {
      await waitForPeerOpen(peer, 18000);
      return peer;
    } catch (err) {
      lastErr = err;
      peer.destroy();
      if (i < attempts - 1) await sleep(1500 + i * 500);
    }
  }
  throw lastErr || new Error('Could not register this session. Wait a few seconds and try again.');
}

function createPeer(id) {
  return new Peer(peerOptions(id));
}

async function createPeerWithRetry(id, attempts = 3) {
  let lastErr;
  for (let i = 0; i < attempts; i += 1) {
    const peer = createPeer(id);
    try {
      await waitForPeerOpen(peer, 12000);
      return peer;
    } catch (err) {
      lastErr = err;
      peer.destroy();
      if (i < attempts - 1) await sleep(400);
    }
  }
  throw lastErr || new Error('Could not join pairing network.');
}

async function connectToRelay(code, peer, role, onStatus) {
  const relayId = peerIdForCode(code);
  const totalMs = window.CASTER_CONFIG?.CONNECT_TOTAL_MS || 45000;
  const timeoutMs = window.CASTER_CONFIG?.CONNECT_TIMEOUT_MS || 10000;
  const retryMs = window.CASTER_CONFIG?.CONNECT_RETRY_MS || 500;
  const deadline = Date.now() + totalMs;
  let lastErr;
  let pass = 0;

  while (Date.now() < deadline) {
    pass += 1;
    onStatus?.(pass === 1 ? 'Finding phone relay…' : 'Still trying…');
    let conn;
    try {
      const remaining = deadline - Date.now();
      if (remaining <= 500) break;
      conn = peer.connect(relayId, { reliable: true });
      await waitForConnection(conn, Math.min(timeoutMs, remaining));
      sendData(conn, { type: 'hello', role, peerId: peer.id });
      const ackMs = Math.min(12000, deadline - Date.now());
      if (ackMs <= 500) throw new Error('Timed out waiting for phone relay.');
      await waitForRelayAck(conn, ackMs);
      return conn;
    } catch (err) {
      lastErr = err;
      try { conn?.close?.(); } catch { /* ignore */ }
      const wait = Math.min(retryMs, deadline - Date.now());
      if (wait > 0) await sleep(wait);
    }
  }

  throw lastErr || new Error('Could not reach phone relay. Keep the View Caster app open with a green dot.');
}

function sendData(conn, data) {
  if (conn?.open) conn.send(data);
}

window.CasterSignaling = {
  APP_VERSION,
  generateCode,
  peerIdForCode,
  desktopPeerIdForCode,
  camPeerIdForCode,
  hasCameraSupport,
  createPeer,
  createPeerWithRetry,
  createNamedPeerWithRetry,
  connectToRelay,
  connectAny,
  waitForIncomingHello,
  withTimeout,
  waitForPeerOpen,
  waitForConnection,
  waitForRelayAck,
  sendData,
  sleep,
};
