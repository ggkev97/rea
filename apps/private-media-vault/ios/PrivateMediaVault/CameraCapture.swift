import AVFoundation
import SwiftUI
import UIKit

struct CameraCaptureView: View {
    @Environment(VaultModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var camera = CameraController()

    var body: some View {
        NavigationStack {
            ZStack {
                CameraPreview(session: camera.session)
                    .ignoresSafeArea()
                VStack {
                    Spacer()
                    HStack(spacing: 24) {
                        Button("Photo") { camera.takePhoto { url in importCapture(url) } }
                            .frame(minWidth: 88, minHeight: 44)
                            .buttonStyle(.borderedProminent)
                        Button(camera.recording ? "Stop" : "Record") {
                            camera.toggleRecording { url in importCapture(url) }
                        }
                        .frame(minWidth: 88, minHeight: 44)
                        .buttonStyle(.bordered)
                    }
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Camera")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Close") { camera.stop(); dismiss() }
                    .frame(minHeight: 44)
            }
            .onAppear { camera.start() }
            .onDisappear { camera.stop() }
            .alert("Camera", isPresented: errorShown) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(camera.errorMessage ?? "")
            }
        }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { camera.errorMessage != nil }, set: { if !$0 { camera.errorMessage = nil } })
    }

    private func importCapture(_ url: URL) {
        do {
            try model.importFile(url, source: .camera)
            try? FileManager.default.removeItem(at: url)
        } catch {
            model.statusMessage = publicMessage(error)
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.previewLayer.session = session
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

final class CameraController: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    @Published var recording = false
    @Published var errorMessage: String?
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var photoHandler: ((URL) -> Void)?
    private var movieHandler: ((URL) -> Void)?

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async { self.configure() }
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { self.configure() }
                    else { self.errorMessage = "Camera access is off." }
                }
            }
        default:
            errorMessage = "Camera access is off in Settings."
        }
    }

    func stop() {
        if session.isRunning { session.stopRunning() }
    }

    func takePhoto(completion: @escaping (URL) -> Void) {
        photoHandler = completion
        photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }

    func toggleRecording(completion: @escaping (URL) -> Void) {
        if movieOutput.isRecording {
            movieOutput.stopRecording()
            return
        }
        movieHandler = completion
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        movieOutput.startRecording(to: url, recordingDelegate: self)
        recording = true
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            errorMessage = error.localizedDescription
            return
        }
        guard let data = photo.fileDataRepresentation() else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        do {
            try data.write(to: url, options: .completeFileProtection)
            photoHandler?(url)
        } catch {
            errorMessage = "The photo could not be stored."
        }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        recording = false
        if error == nil { movieHandler?(outputFileURL) }
        else { errorMessage = "The recording did not finish." }
    }

    private func configure() {
        guard session.inputs.isEmpty else {
            if !session.isRunning { DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() } }
            return
        }
        session.beginConfiguration()
        session.sessionPreset = .high
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else {
            errorMessage = "No camera is available."
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        if let microphone = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: microphone),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        session.commitConfiguration()
        DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
    }
}
