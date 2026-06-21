/**
 * Desktop WebRTC viewer — receives phone camera stream via WebSocket signaling.
 */
(function () {
  const ICE = window.CASTER_CONFIG?.ICE_SERVERS || [{ urls: 'stun:stun.l.google.com:19302' }];

  function createPeerConnection(onTrack, onTrackLost) {
    const pc = new RTCPeerConnection({ iceServers: ICE, bundlePolicy: 'max-bundle' });
    const seenStreamIds = new Set();

    function deliverTrack(event) {
      const stream = event.streams?.[0] || new MediaStream([event.track]);
      if (event.streams?.[0]?.id) {
        if (seenStreamIds.has(event.streams[0].id)) return;
        seenStreamIds.add(event.streams[0].id);
      }
      onTrack(stream, event.track);
      event.track.onunmute = () => onTrack(stream, event.track);
      event.track.onended = () => onTrackLost?.(stream, event.track);
    }

    pc.ontrack = deliverTrack;
    pc.onconnectionstatechange = () => {
      if (pc.connectionState === 'failed' || pc.connectionState === 'closed') {
        onTrackLost?.(null, null);
      }
    };
    pc.oniceconnectionstatechange = () => {
      if (pc.iceConnectionState === 'failed' || pc.iceConnectionState === 'disconnected') {
        onTrackLost?.(null, null);
      }
    };
    return pc;
  }

  function bindIce(pc, ws, viewerId) {
    pc.onicecandidate = (e) => {
      if (!e.candidate) return;
      CasterWS.send(ws, {
        type: 'ice-candidate',
        candidate: e.candidate.candidate,
        sdpMLineIndex: e.candidate.sdpMLineIndex,
        sdpMid: e.candidate.sdpMid,
        viewerId,
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

  async function handleOffer(pc, ws, msg, viewerId) {
    await pc.setRemoteDescription({ type: 'offer', sdp: msg.sdp });
    const answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    CasterWS.send(ws, { type: 'answer', sdp: answer.sdp, viewerId });
  }

  window.CasterWebRTCViewer = { createPeerConnection, bindIce, handleRemoteIce, handleOffer };
})();
