import Foundation
import UIKit
import CoreMedia
import MWDATCamera
import MWDATCore

/// Glasses photo capture only — Meta registration lives in BypassMetaCompanion.
@MainActor
final class WearablesManager {
    weak var meta: BypassMetaCompanion?

    var onVideoFrame: ((VideoFrame) -> Void)?
    var onPhotoSampleBuffer: ((CMSampleBuffer) -> Void)?

    private var cameraStream: MWDATCamera.Stream?
    private var stateToken: Any?
    private var frameToken: Any?
    private var photoToken: Any?
    private var photoCaptureContinuation: CheckedContinuation<Data, Error>?

    var canStreamFromGlasses: Bool {
        guard let meta else { return false }
        return meta.isRegistered && meta.cameraGranted
    }

    func captureGlassesPhoto(status: @escaping (String) -> Void) async throws {
        guard let meta else {
            throw WearablesStreamError.notRegistered
        }
        guard meta.isRegistered else {
            throw WearablesStreamError.notRegistered
        }
        guard meta.cameraGranted else {
            throw WearablesStreamError.cameraDenied
        }

        status("Preparing glasses for photo...")
        let ready = await meta.ensureReadyDeviceSession(showStatus: false, timeoutSeconds: 30)
        guard ready else {
            throw WearablesStreamError.noEligibleDevice
        }

        if cameraStream != nil {
            await stopCameraStreamOnly()
        }

        try await startGlassesStreamForCapture(quiet: true)
        status("Capturing photo from glasses...")

        let photoData = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            photoCaptureContinuation = continuation
            Task { @MainActor in
                guard let stream = self.cameraStream else {
                    continuation.resume(throwing: WearablesStreamError.streamFailed)
                    return
                }
                _ = await self.triggerSinglePhotoCapture(on: stream)
            }
        }

        if let sample = sampleBufferFromJPEG(photoData) {
            onPhotoSampleBuffer?(sample)
        }

        await stopCameraStreamOnly()
        status("Photo captured")
    }

    func startGlassesStream(status: @escaping (String) -> Void) async throws {
        try await captureGlassesPhoto(status: status)
    }

    func stopGlassesStream() {
        Task { await stopCameraStreamOnly() }
    }

    private func startGlassesStreamForCapture(quiet: Bool) async throws {
        try await startGlassesStreamAttempt(quiet: quiet, photoCaptureOnly: true)
    }

    private func startGlassesStreamAttempt(quiet: Bool, photoCaptureOnly: Bool) async throws {
        guard let meta else {
            throw WearablesStreamError.notRegistered
        }

        let deadline = Date().addingTimeInterval(20)
        var lastError: Error = WearablesStreamError.noEligibleDevice
        while Date() < deadline {
            do {
                guard await meta.ensureReadyDeviceSession(showStatus: false, timeoutSeconds: 15) else {
                    throw WearablesStreamError.noEligibleDevice
                }
                let session = try await meta.getStartedSessionForCapture()
                try await attachCameraStream(to: session, quiet: quiet, photoCaptureOnly: photoCaptureOnly)
                return
            } catch {
                lastError = error
                try? await Task.sleep(nanoseconds: 450_000_000)
            }
        }
        throw lastError
    }

    private func attachCameraStream(
        to session: DeviceSession,
        quiet: Bool,
        photoCaptureOnly: Bool
    ) async throws {
        let stream = try await createCameraStreamWithRetry(session)
        cameraStream = stream

        stateToken = stream.statePublisher.listen { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                let text = String(describing: state).lowercased()
                if photoCaptureOnly,
                   self.photoCaptureContinuation != nil,
                   text.contains("streaming") || text.contains("started") {
                    _ = await self.triggerSinglePhotoCapture(on: stream)
                }
                if !quiet, let meta = self.meta {
                    meta.wearablesStatus = "Stream: \(String(describing: state))"
                }
            }
        }

        photoToken = stream.photoDataPublisher.listen { [weak self] photoData in
            Task { @MainActor in
                guard let self, let continuation = self.photoCaptureContinuation else { return }
                self.photoCaptureContinuation = nil
                continuation.resume(returning: photoData.data)
            }
        }

        frameToken = stream.videoFramePublisher.listen { [weak self] frame in
            Task { @MainActor in
                self?.onVideoFrame?(frame)
            }
        }

        await stream.start()
    }

    private func createCameraStreamWithRetry(_ session: DeviceSession, maxAttempts: Int = 10) async throws -> MWDATCamera.Stream {
        let config = StreamConfiguration(
            videoCodec: .raw,
            resolution: .low,
            frameRate: 24
        )
        for attempt in 1...maxAttempts {
            if let stream = try? session.addStream(config: config) {
                return stream
            }
            meta?.wearablesStatus = "Preparing camera stream (\(attempt)/\(maxAttempts))..."
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw WearablesStreamError.streamFailed
    }

    private func triggerSinglePhotoCapture(on stream: MWDATCamera.Stream) async -> Bool {
        for _ in 1...4 {
            guard photoCaptureContinuation != nil else { return true }
            if stream.capturePhoto(format: PhotoCaptureFormat.jpeg) {
                return true
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    private func stopCameraStreamOnly() async {
        stateToken = nil
        frameToken = nil
        photoToken = nil
        await cameraStream?.stop()
        cameraStream = nil
    }

    enum WearablesStreamError: LocalizedError {
        case notRegistered
        case cameraDenied
        case streamFailed
        case noEligibleDevice
        case sessionFailed(String)

        var errorDescription: String? {
            switch self {
            case .notRegistered: return "Register with Meta AI first."
            case .cameraDenied: return "Allow camera in Meta AI first."
            case .streamFailed: return "Could not start glasses camera."
            case .noEligibleDevice: return "No eligible glasses. Wear them, open Meta AI, Bluetooth on."
            case .sessionFailed(let detail): return detail
            }
        }
    }
}

private func sampleBufferFromJPEG(_ data: Data) -> CMSampleBuffer? {
    guard let image = UIImage(data: data), let cgImage = image.cgImage else { return nil }
    let width = cgImage.width
    let height = cgImage.height
    var pixelBuffer: CVPixelBuffer?
    let attrs = [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
    ] as CFDictionary
    guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &pixelBuffer) == kCVReturnSuccess,
          let buffer = pixelBuffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let context = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer),
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { return nil }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    var format: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format)
    guard let format else { return nil }
    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
    var sampleBuffer: CMSampleBuffer?
    CMSampleBufferCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: buffer,
        dataReady: true,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: format,
        sampleTiming: &timing,
        sampleBufferOut: &sampleBuffer
    )
    return sampleBuffer
}
