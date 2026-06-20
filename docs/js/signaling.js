/**
 * Shared WebSocket + WebRTC helpers for Meta Display View Caster
 */

function getSignalingUrl() {
  const cfg = window.CASTER_CONFIG?.SIGNALING_URL || '';
  if (!cfg || cfg.includes('YOUR-SERVER')) {
    return null;
  }
  return cfg.replace(/^http/, 'ws');
}

function createSignalingConnection(onMessage, onClose) {
  const url = getSignalingUrl();
  if (!url) {
    throw new Error('Signaling server not configured. Edit docs/config.js with your server URL.');
  }

  const ws = new WebSocket(url);

  ws.onopen = () => {
    console.log('[caster] connected to signaling server');
  };

  ws.onmessage = (event) => {
    let msg;
    try {
      msg = JSON.parse(event.data);
    } catch {
      return;
    }
    onMessage(msg);
  };

  ws.onerror = () => {
    console.error('[caster] WebSocket error');
  };

  ws.onclose = () => {
    onClose?.();
  };

  return ws;
}

function send(ws, payload) {
  if (ws?.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(payload));
  }
}

function createPeerConnection(onTrack, onIceCandidate) {
  const iceServers = window.CASTER_CONFIG?.ICE_SERVERS || [{ urls: 'stun:stun.l.google.com:19302' }];
  const pc = new RTCPeerConnection({ iceServers });

  pc.ontrack = (event) => {
    onTrack?.(event);
  };

  pc.onicecandidate = (event) => {
    if (event.candidate) {
      onIceCandidate?.(event.candidate);
    }
  };

  pc.onconnectionstatechange = () => {
    console.log('[caster] ICE connection state:', pc.connectionState);
  };

  return pc;
}

window.CasterSignaling = {
  getSignalingUrl,
  createSignalingConnection,
  send,
  createPeerConnection,
};
