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

    private var pc: RTCPeerConnection?
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

    func startStream() {
        guard pc == nil else { return }
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
        pc = factory.peerConnection(with: config, constraints: constraints, delegate: self)

        let source = factory.videoSource()
        let capturer = FrameCapturer()
        let track = factory.videoTrack(with: source, trackId: "video0")
        videoSource = source
        frameCapturer = capturer
        localVideoTrack = track
        pc?.add(track, streamIds: ["stream0"])

        let offerConstraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "false", "OfferToReceiveVideo": "false"],
            optionalConstraints: nil
        )
        pc?.offer(for: offerConstraints) { [weak self] sdp, error in
            guard let self, let sdp, error == nil else { return }
            let offerSdp = sdp.sdp
            let signaling = self.signaling
            self.pc?.setLocalDescription(sdp) { err in
                guard err == nil else { return }
                Task { @MainActor in
                    signaling?.sendOffer(offerSdp)
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

    func handleAnswer(_ sdp: String) {
        guard let pc else { return }
        let desc = RTCSessionDescription(type: .answer, sdp: sdp)
        pc.setRemoteDescription(desc) { error in
            if let error {
                NSLog("CastRelay: setRemoteDescription failed: \(error.localizedDescription)")
            }
        }
    }

    func handleRemoteIce(candidate: String, sdpMLineIndex: Int32, sdpMid: String?) {
        let ice = RTCIceCandidate(sdp: candidate, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
        pc?.add(ice)
    }

    func stopStream() {
        frameCapturer = nil
        localVideoTrack = nil
        videoSource = nil
        pc?.close()
        pc = nil
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
        Task { @MainActor [weak self] in
            self?.signaling?.sendIceCandidate(candidateSdp, sdpMLineIndex: mLineIndex, sdpMid: mid)
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
