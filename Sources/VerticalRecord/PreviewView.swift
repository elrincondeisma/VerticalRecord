import AVFoundation
import SwiftUI

/// Vista previa: una capa que muestra el mismo búfer que va al grabador, sin
/// copias. Se le encolan CMSampleBuffers marcados «mostrar ya».
final class PreviewLayerHost {
    let layer = AVSampleBufferDisplayLayer()

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0.06, alpha: 1)
    }

    func show(_ buffer: CVPixelBuffer, at time: CMTime) {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format) == noErr,
              let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [CFMutableDictionary],
           let first = attachments.first {
            CFDictionarySetValue(first,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }
}

struct PreviewView: NSViewRepresentable {
    let host: PreviewLayerHost

    func makeNSView(context: Context) -> NSView {
        let view = LayerView()
        view.wantsLayer = true
        view.layer = host.layer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class LayerView: NSView {
        override func layout() {
            super.layout()
            layer?.frame = bounds
        }
    }
}
