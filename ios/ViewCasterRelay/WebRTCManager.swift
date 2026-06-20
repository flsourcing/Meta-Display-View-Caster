import Foundation
import WebRTC

final class WebRTCManager: NSObject {
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()

    private var pc: RTCPeerConnection?
    private var capturer: RTCCameraVideoCapturer?
    private var videoSource: RTCVideoSource?
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
        pc = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self)

        videoSource = Self.factory.videoSource()
        capturer = RTCCameraVideoCapturer(delegate: videoSource!)
        localVideoTrack = Self.factory.videoTrack(with: videoSource!, trackId: "video0")
        pc?.add(localVideoTrack!, streamIds: ["stream0"])

        startCamera()

        let offerConstraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "false", "OfferToReceiveVideo": "false"],
            optionalConstraints: nil
        )
        pc?.offer(for: offerConstraints) { [weak self] sdp, error in
            guard let self, let sdp, error == nil else { return }
            self.pc?.setLocalDescription(sdp) { err in
                guard err == nil else { return }
                Task { @MainActor in
                    self.signaling?.sendOffer(sdp.sdp)
                }
            }
        }
    }

    func stopStream() {
        capturer?.stopCapture()
        capturer = nil
        localVideoTrack = nil
        videoSource = nil
        pc?.close()
        pc = nil
    }

    private func startCamera() {
        guard let capturer else { return }
        guard let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == .back })
            ?? RTCCameraVideoCapturer.captureDevices().first else { return }
        guard let format = RTCCameraVideoCapturer.supportedFormats(for: device).last else { return }
        capturer.startCapture(with: device, format: format, fps: 30)
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
        Task { @MainActor in
            signaling?.sendIceCandidate(
                candidate.sdp,
                sdpMLineIndex: candidate.sdpMLineIndex,
                sdpMid: candidate.sdpMid
            )
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
