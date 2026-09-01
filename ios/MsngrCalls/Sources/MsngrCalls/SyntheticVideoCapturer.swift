import Foundation
import CoreVideo
import WebRTC

/// A camera stand-in for machines without one (the simulator): feeds the
/// video source a moving color-band pattern at a steady rate, so the whole
/// video pipeline — encoder, transport, remote render — runs for real.
final class SyntheticVideoCapturer: RTCVideoCapturer {
    private let width = 640
    private let height = 480
    private let fps = 15
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "msngr.synthetic-video")

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(1000 / fps))
        timer.setEventHandler { [weak self] in self?.emitFrame() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func emitFrame() {
        var pixelBuffer: CVPixelBuffer?
        // video-range NV12, the camera's own format: the Metal renderer of
        // the local preview draws it where full-range comes out blank
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
                            &pixelBuffer)
        guard let buffer = pixelBuffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        let t = Date().timeIntervalSince1970
        let phase = Int(t * 60) % height
        if let yPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let y = yPlane.assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                // horizontal bands drifting downward: motion the encoder sees
                let value = UInt8(64 + (((row + phase) / 40) % 4) * 48)
                memset(y + row * stride, Int32(value), width)
            }
        }
        if let uvPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            let uv = uvPlane.assumingMemoryBound(to: UInt8.self)
            for row in 0..<(height / 2) {
                for col in 0..<(width / 2) {
                    uv[row * stride + col * 2] = UInt8((row + phase) % 255)      // Cb
                    uv[row * stride + col * 2 + 1] = UInt8((col + phase) % 255)  // Cr
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: buffer)
        // monotonic, like the camera's presentation clock: a wall-clock stamp
        // is decades ahead of it and the frame is dropped as misaligned
        let frame = RTCVideoFrame(buffer: rtcBuffer, rotation: ._0,
                                  timeStampNs: Int64(DispatchTime.now().uptimeNanoseconds))
        delegate?.capturer(self, didCapture: frame)
    }
}
