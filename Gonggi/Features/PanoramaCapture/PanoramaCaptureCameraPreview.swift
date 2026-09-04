import AVFoundation
import SwiftUI
import UIKit

/// Full-screen live camera preview. Never crops to the internal strip region.
struct PanoramaCaptureCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        view.applyPortraitOrientation()
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.videoPreviewLayer.session !== session {
            uiView.videoPreviewLayer.session = session
        }
        uiView.videoPreviewLayer.videoGravity = .resizeAspectFill
        uiView.applyPortraitOrientation()
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            videoPreviewLayer.frame = bounds
            applyPortraitOrientation()
        }

        func applyPortraitOrientation() {
            PanoramaFrameOrientation.applyPortraitRotation(
                to: videoPreviewLayer.connection
            )
        }
    }
}
