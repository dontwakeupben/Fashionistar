import SwiftUI
import Combine
import AVFoundation
import AppKit
import Vision

struct Project: View {
    @StateObject private var vm = CameraViewModel()
        
    @State private var userImage: NSImage?
    
    // In Project.swift

    private func openImagePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        
        if panel.runModal() == .OK {
            guard let url = panel.url else { return }
            
            // --- THIS IS THE FIX ---
            
            // 1. Request permission to access the file
            guard url.startAccessingSecurityScopedResource() else {
                print("Security: Failed to start accessing resource.")
                // You might want to show an alert to the user here
                return
            }
            
            // 2. Now that we have access, load the image.
            // We do this on a background thread so it doesn't freeze the UI
            DispatchQueue.global(qos: .userInitiated).async {
                let image = NSImage(contentsOf: url)
                
                // 3. Stop accessing the resource (always do this)
                url.stopAccessingSecurityScopedResource()
                
                // 4. Update the UI on the main thread
                DispatchQueue.main.async {
                    self.userImage = image
                    
                    if self.userImage == nil {
                        print("Failed to load image, file might be corrupt or in an unsupported format.")
                    }
                }
            }
        }
    }

    
    var body: some View {
        ZStack{
            CameraPreview(session: vm.session, observations: vm.observations,customOverlayImage: userImage)
                .ignoresSafeArea() // Available on macOS SwiftUI as well
            VStack{
                Spacer()
                Button("Upload Custom Image") {
                    openImagePicker()
                }
                .padding()
                .background(.black.opacity(0.6))
                .foregroundColor(.white)
                .cornerRadius(10)
                .padding() // Add padding from the edge
            }
        }
    }
}

// MODIFIED: Conform to AVCaptureVideoDataOutputSampleBufferDelegate
final class CameraViewModel: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    public let session = AVCaptureSession()
    
    // NEW: Published property to hold detection results
    @Published var observations: [VNRecognizedObjectObservation] = []
    
    // NEW: Vision request handler
    private var visionRequest: VNCoreMLRequest?
    
    override init() {
        super.init()
        
        // NEW: Load the model and setup the request
        setupVision()
        
        // This function already existed, just runs after vision setup
        requestPermissionAndSetup()
    }
    
    // NEW: Function to load the Core ML model
    private func setupVision() {
        guard let modelURL = Bundle.main.url(forResource: "Punching Bag Detection 1 Iteration 140", withExtension: "mlmodelc") else {
            print("Failed to find Core ML model file.")
            return
        }
        
        do {
            let visionModel = try VNCoreMLModel(for: MLModel(contentsOf: modelURL))
            
            // Create the request with a completion handler
            self.visionRequest = VNCoreMLRequest(model: visionModel, completionHandler: visionCompletionHandler)
            self.visionRequest?.imageCropAndScaleOption = .scaleFill
            
        } catch {
            print("Failed to load Core ML model: \(error)")
        }
    }
    
    // NEW: Completion handler for the Vision request
    private func visionCompletionHandler(request: VNRequest, error: Error?) {
        if let error = error {
            print("Vision request failed: \(error.localizedDescription)")
            return
        }
   
        
        // Get the results which are VNRecognizedObjectObservation for object detection
        guard let results = request.results as? [VNRecognizedObjectObservation] else {
            return
        }
        
        // Update the published observations on the main thread
        DispatchQueue.main.async {
            self.observations = results
        }
    }

    private func requestPermissionAndSetup() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        self.setupCamera()
                    } else {
                        print("Camera access denied by user.")
                    }
                }
            }
        case .denied, .restricted:
            print("Camera access denied or restricted. Update privacy settings.")
        @unknown default:
            print("Unknown camera authorization status.")
        }
    }

    private func setupCamera() {
        session.beginConfiguration()
        session.sessionPreset = .photo

        guard let device = AVCaptureDevice.default(for: .video) else {
            print("No video capture device available.")
            session.commitConfiguration()
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
            } else {
                print("Cannot add camera input to session.")
            }
        } catch {
            print("Failed to create AVCaptureDeviceInput: \(error)")
            session.commitConfiguration()
            return
        }

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        
        // NEW: Set the delegate to receive frames
        // Use a serial queue for frame processing to avoid conflicts
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "cameraQueue"))
        
        if session.canAddOutput(output) {
            session.addOutput(output)
        } else {
            print("Cannot add video output to session.")
        }

        session.commitConfiguration()
        session.startRunning()
    }
    
    // NEW: Delegate method for AVCaptureVideoDataOutput
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Get the pixel buffer from the sample buffer
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        
        // Ensure our vision request is set up
        guard let visionRequest = self.visionRequest else {
            print("Vision request not initialized.")
            return
        }
        
        // Create a request handler for the current frame
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        
        do {
            // Perform the Vision request
            try handler.perform([visionRequest])
        } catch {
            print("Failed to perform Vision request: \(error)")
        }
    }
}



struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    let observations: [VNRecognizedObjectObservation]
    
    // This will now be the ONLY source for the overlay image
    let customOverlayImage: NSImage?

    class Coordinator: NSObject {
        var drawingLayer: CALayer?
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.wantsLayer = true

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = view.bounds
        previewLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        
        let drawingLayer = CALayer()
        drawingLayer.frame = view.bounds
        drawingLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        
        view.layer?.addSublayer(previewLayer)
        view.layer?.addSublayer(drawingLayer)
        
        context.coordinator.drawingLayer = drawingLayer
        
        return view
    }


    func updateNSView(_ nsView: NSView, context: Context) {
        guard let previewLayer = nsView.layer?.sublayers?.first as? AVCaptureVideoPreviewLayer,
              let drawingLayer = context.coordinator.drawingLayer else {
            return
        }
        
        previewLayer.frame = nsView.bounds
        drawingLayer.frame = nsView.bounds
        
        drawingLayer.sublayers = nil // Clear old drawings
        
        for observation in observations {
            guard observation.confidence > 0.8 else { continue }
            
            let viewRect = previewLayer.layerRectConverted(fromMetadataOutputRect: observation.boundingBox)
            
            // The call is the same, but the function's logic will be different
            let overlayLayers = createObjectOverlay(frame: viewRect, label: observation.labels.first?.identifier ?? "Object", confidence: observation.confidence)
            
            for layer in overlayLayers {
                drawingLayer.addSublayer(layer)
            }
        }
    }
    
    // MODIFIED: This function now *only* uses `customOverlayImage` if it exists.
    // There is no fallback to "ObjectIcon".
    private func createObjectOverlay(frame: CGRect, label: String, confidence: Float) -> [CALayer] {
        var layers: [CALayer] = []
        
        // --- 1. Create the Bounding Box Layer ---
        let boxLayer = CALayer()
        boxLayer.frame = frame
        boxLayer.borderWidth = 0
        boxLayer.borderColor = NSColor.red.cgColor
        boxLayer.cornerRadius = 4.0
        layers.append(boxLayer)

        // --- 2. Create the Image Layer (Icon) ---
        
        // MODIFIED LOGIC: We ONLY use customOverlayImage now.
        // If customOverlayImage is nil, no image will be drawn.
        if let iconImage = self.customOverlayImage { // Directly use the user's image
            let imageLayer = CALayer()
            
            print(frame.width)
            
            let iconSize: CGFloat = (frame.width)*2// You can still control the size
            
            imageLayer.frame = CGRect(
                x: frame.midX - (iconSize / 2),
                y: frame.minY,
                width: iconSize,
                height: iconSize
            )
            
            imageLayer.contents = iconImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
            imageLayer.contentsGravity = .resizeAspect
            layers.append(imageLayer)
        }
        // If customOverlayImage is nil, this 'if let' block is skipped,
        // and no image layer is added.
        
        // --- 3. Create the Text Layer (Label) ---
        // (This part is unchanged)
        let textLayer = CATextLayer()
        textLayer.string = "\(label) (\(Int(confidence * 100))%)"
        textLayer.fontSize = 20.0
        textLayer.foregroundColor = NSColor.white.cgColor
        textLayer.backgroundColor = NSColor.red.withAlphaComponent(0.8).cgColor
// ... (rest of text layer setup)
        
        // (This logic to position the text is also unchanged)
        let textSize = textLayer.preferredFrameSize()
        let textYPosition: CGFloat
        
        // Important: Adjust textYPosition logic to account for image potentially not being present
        // If layers.count is 1 (only box), then no image was added.
        if layers.count > 1 { // Check if an image was successfully added (box + image = 2+ layers)
            textYPosition = frame.minY - (frame.minY - layers[1].frame.minY) - textSize.height - 5 // Below icon
        } else { // No icon, position directly above the box
            textYPosition = frame.minY - textSize.height - 5
        }
//
//        textLayer.frame = CGRect(
//            x: frame.midX - (textSize.width + 10) / 2,
//            y: textYPosition,
//            width: textSize.width + 10,
//            height: textSize.height
//        )
//        layers.append(textLayer)
        
        return layers
    }
}

#Preview {
    Project()
}
