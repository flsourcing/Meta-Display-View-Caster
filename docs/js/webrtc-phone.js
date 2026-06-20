/**
 * Phone WebRTC — streams camera to desktop via WebSocket signaling.
 */
(function () {
  const ICE = window.CASTER_CONFIG?.ICE_SERVERS || [{ urls: 'stun:stun.l.google.com:19302' }];

  let pc = null;
  let localStream = null;

  function createPeerConnection() {
    const pc = new RTCPeerConnection({ iceServers: ICE });
    return pc;
  }

  function bindIce(pc, ws) {
    pc.onicecandidate = (e) => {
      if (!e.candidate) return;
      CasterWS.send(ws, {
        type: 'ice-candidate',
        candidate: e.candidate.candidate,
        sdpMLineIndex: e.candidate.sdpMLineIndex,
        sdpMid: e.candidate.sdpMid,
      });
    };
  }

  async function handleRemoteIce(pc, msg) {
    if (!msg.candidate) return;
    await pc.addIceCandidate({
      candidate: msg.candidate,
      sdpMLineIndex: msg.sdpMLineIndex,
      sdpMid: msg.sdpMid || null,
    });
  }

  async function handleAnswer(pc, msg) {
    await pc.setRemoteDescription({ type: 'answer', sdp: msg.sdp });
  }

  async function startStream(ws) {
    stopStream();
    pc = createPeerConnection();
    bindIce(pc, ws);

    try {
      localStream = await navigator.mediaDevices.getUserMedia({
        video: { facingMode: 'environment', width: { ideal: 1280 }, height: { ideal: 720 } },
        audio: false,
      });
    } catch {
      CasterWS.send(ws, { type: 'stream-error', message: 'Allow camera access in Settings.' });
      stopStream();
      return;
    }

    localStream.getTracks().forEach((t) => pc.addTrack(t, localStream));

    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    CasterWS.send(ws, { type: 'offer', sdp: offer.sdp, target: 'desktop' });
    CasterWS.send(ws, { type: 'stream-started' });
  }

  function stopStream() {
    localStream?.getTracks().forEach((t) => t.stop());
    localStream = null;
    pc?.close();
    pc = null;
  }

  window.CasterWebRTCPhone = { startStream, stopStream, handleRemoteIce, handleAnswer };
})();
