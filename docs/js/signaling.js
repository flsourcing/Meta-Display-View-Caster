/**
 * WebSocket signaling + WebRTC helpers
 */

const APP_VERSION = '7';

function getSignalingUrl() {
  const url = window.CASTER_CONFIG?.SIGNALING_URL || '';
  if (!url) throw new Error('Signaling server not configured.');
  return url.replace(/^http/i, 'ws');
}

function getHttpUrl() {
  return getSignalingUrl().replace(/^ws/i, 'http');
}

async function wakeServer() {
  const res = await fetch(`${getHttpUrl()}/health`, { cache: 'no-store' });
  if (!res.ok) throw new Error('Signaling server is not running. Deploy it on Render first (see README).');
  return res.json();
}

function createSignalingConnection(onMessage, onClose) {
  const ws = new WebSocket(getSignalingUrl());

  ws.onopen = () => console.log('[caster] signaling connected');

  ws.onmessage = (event) => {
    try {
      onMessage(JSON.parse(event.data));
    } catch {
      /* ignore */
    }
  };

  ws.onerror = () => console.error('[caster] signaling error');
  ws.onclose = () => onClose?.();

  return ws;
}

function send(ws, payload) {
  if (ws?.readyState === WebSocket.OPEN) ws.send(JSON.stringify(payload));
}

function waitForOpen(ws, timeoutMs = 30000) {
  if (ws.readyState === WebSocket.OPEN) return Promise.resolve(ws);
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Could not reach signaling server. Wait 30 seconds and try again (server may be waking up).')), timeoutMs);
    ws.addEventListener('open', () => { clearTimeout(timer); resolve(ws); }, { once: true });
    ws.addEventListener('error', () => { clearTimeout(timer); reject(new Error('Signaling server unreachable.')); }, { once: true });
  });
}

function waitForMessage(ws, type, timeoutMs = 30000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Connection timed out. Check the code on your glasses and try again.')), timeoutMs);
    const handler = (event) => {
      try {
        const msg = JSON.parse(event.data);
        if (msg.type === type) {
          clearTimeout(timer);
          ws.removeEventListener('message', handler);
          resolve(msg);
        } else if (msg.type === 'error') {
          clearTimeout(timer);
          ws.removeEventListener('message', handler);
          reject(new Error(msg.message));
        }
      } catch {
        /* ignore */
      }
    };
    ws.addEventListener('message', handler);
  });
}

function createPeerConnection(onTrack, onIceCandidate) {
  const pc = new RTCPeerConnection({
    iceServers: window.CASTER_CONFIG?.ICE_SERVERS || [{ urls: 'stun:stun.l.google.com:19302' }],
  });
  pc.ontrack = (e) => onTrack?.(e);
  pc.onicecandidate = (e) => { if (e.candidate) onIceCandidate?.(e.candidate); };
  return pc;
}

function hasCameraSupport() {
  return !!(navigator.mediaDevices?.getUserMedia);
}

function generateCode() {
  return String(Math.floor(100000 + Math.random() * 900000));
}

window.CasterSignaling = {
  APP_VERSION,
  wakeServer,
  getSignalingUrl,
  createSignalingConnection,
  send,
  waitForOpen,
  waitForMessage,
  createPeerConnection,
  hasCameraSupport,
  generateCode,
};
