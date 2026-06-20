import Foundation
import WebRTC
import CoreMedia
import MWDATCamera

final class FrameCapturer: RTCVideoCapturer {}

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

    func startStream() {
        guard pc == nil else { return }
        let config = RTCConfiguration()
        config.iceServers = [
            RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"]),
            RTCIceServer(urlStrings: ["turn:openrelay.metered.ca:443"], username: "openrelayproject", credential: "openrelayproject"),
        ]
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        pc = factory.peerConnection(with: config, constraints: constraints, delegate: self)

        videoSource = factory.videoSource()
        frameCapturer = FrameCapturer()
        localVideoTrack = factory.videoTrack(with: videoSource!, trackId: "video0")
        pc?.add(localVideoTrack!, streamIds: ["stream0"])

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
        guard let videoSource, let frameCapturer else { return }
        let sampleBuffer = frame.sampleBuffer
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
                NSLog("ViewCaster: setRemoteDescription failed: \(error.localizedDescription)")
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
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let candidateSdp = candidate.sdp
        let mLineIndex = candidate.sdpMLineIndex
        let mid = candidate.sdpMid
        let signaling = self.signaling
        Task { @MainActor in
            signaling?.sendIceCandidate(
                candidateSdp,
                sdpMLineIndex: mLineIndex,
                sdpMid: mid
            )
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
