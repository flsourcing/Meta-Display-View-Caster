import Foundation
import WebRTC
import CoreMedia
import MWDATCamera

final class FrameCapturer: RTCVideoCapturer {}

@MainActor
final class WebRTCManager: NSObject {
    private lazy var factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()

    private struct ViewerConnection {
        let viewerId: String
        let pc: RTCPeerConnection
    }

    private var viewerConnections: [String: ViewerConnection] = [:]
    private var pcToViewerId: [ObjectIdentifier: String] = [:]
    private var videoSource: RTCVideoSource?
    private var frameCapturer: FrameCapturer?
    private var localVideoTrack: RTCVideoTrack?
    private weak var signaling: SignalingClient?

    func attach(signaling: SignalingClient) {
        self.signaling = signaling
    }

    func prepareFactory() {
        _ = factory
    }

    private func ensureSharedVideoTrack() {
        guard localVideoTrack == nil else { return }
        let source = factory.videoSource()
        let capturer = FrameCapturer()
        let track = factory.videoTrack(with: source, trackId: "video0")
        videoSource = source
        frameCapturer = capturer
        localVideoTrack = track
    }

    func startStream() {
        ensureSharedVideoTrack()
    }

    func addViewer(viewerId: String) {
        ensureSharedVideoTrack()
        guard viewerConnections[viewerId] == nil else { return }
        guard let localVideoTrack else { return }

        let config = RTCConfiguration()
        config.iceServers = [
            RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"]),
            RTCIceServer(
                urlStrings: ["turn:openrelay.metered.ca:443"],
                username: "openrelayproject",
                credential: "openrelayproject"
            ),
        ]
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: self) else { return }

        pc.add(localVideoTrack, streamIds: ["stream0"])
        viewerConnections[viewerId] = ViewerConnection(viewerId: viewerId, pc: pc)
        pcToViewerId[ObjectIdentifier(pc)] = viewerId

        let offerConstraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "false", "OfferToReceiveVideo": "false"],
            optionalConstraints: nil
        )
        pc.offer(for: offerConstraints) { [weak self] sdp, error in
            guard let self, let sdp, error == nil else { return }
            let offerSdp = sdp.sdp
            let signaling = self.signaling
            pc.setLocalDescription(sdp) { err in
                guard err == nil else { return }
                Task { @MainActor in
                    signaling?.sendOffer(offerSdp, viewerId: viewerId)
                }
            }
        }
    }

    func pushGlassesFrame(_ frame: VideoFrame) {
        pushSampleBuffer(frame.sampleBuffer)
    }

    func pushSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let videoSource, let frameCapturer else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timeStampNs = Int64(CMTimeGetSeconds(pts) * 1_000_000_000)
        let videoFrame = RTCVideoFrame(buffer: rtcBuffer, rotation: ._0, timeStampNs: timeStampNs)
        videoSource.capturer(frameCapturer, didCapture: videoFrame)
    }

    func handleAnswer(_ sdp: String, viewerId: String) {
        guard let connection = viewerConnections[viewerId] else { return }
        let desc = RTCSessionDescription(type: .answer, sdp: sdp)
        connection.pc.setRemoteDescription(desc) { error in
            if let error {
                NSLog("CastRelay: setRemoteDescription failed for \(viewerId): \(error.localizedDescription)")
            }
        }
    }

    func handleRemoteIce(candidate: String, sdpMLineIndex: Int32, sdpMid: String?, viewerId: String) {
        guard let connection = viewerConnections[viewerId] else { return }
        let ice = RTCIceCandidate(sdp: candidate, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
        connection.pc.add(ice)
    }

    func removeViewer(viewerId: String) {
        guard let connection = viewerConnections.removeValue(forKey: viewerId) else { return }
        pcToViewerId.removeValue(forKey: ObjectIdentifier(connection.pc))
        connection.pc.close()
    }

    func stopStream() {
        for (_, connection) in viewerConnections {
            pcToViewerId.removeValue(forKey: ObjectIdentifier(connection.pc))
            connection.pc.close()
        }
        viewerConnections.removeAll()
        frameCapturer = nil
        localVideoTrack = nil
        videoSource = nil
    }
}

extension WebRTCManager: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let candidateSdp = candidate.sdp
        let mLineIndex = candidate.sdpMLineIndex
        let mid = candidate.sdpMid
        let pcId = ObjectIdentifier(peerConnection)
        Task { @MainActor [weak self] in
            guard let self, let viewerId = self.pcToViewerId[pcId] else { return }
            self.signaling?.sendIceCandidate(candidateSdp, sdpMLineIndex: mLineIndex, sdpMid: mid, viewerId: viewerId)
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
