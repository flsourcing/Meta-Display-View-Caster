/**
 * Desktop WebRTC viewer — receives phone camera stream via WebSocket signaling.
 */
(function () {
  const ICE = window.CASTER_CONFIG?.ICE_SERVERS || [{ urls: 'stun:stun.l.google.com:19302' }];

  function createPeerConnection(onTrack) {
    const pc = new RTCPeerConnection({ iceServers: ICE });
    pc.ontrack = (e) => onTrack(e.streams[0]);
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

  async function handleOffer(pc, ws, msg) {
    await pc.setRemoteDescription({ type: 'offer', sdp: msg.sdp });
    const answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    CasterWS.send(ws, { type: 'answer', sdp: answer.sdp, target: 'relay' });
  }

  window.CasterWebRTCViewer = { createPeerConnection, bindIce, handleRemoteIce, handleOffer };
})();
