//
//  ViewController.swift
//  AlfredQuiz
//
//  Created by Justin Ruan on 2021/4/26.
//

import UIKit
import AVFoundation
import Vision
import Photos

class ViewController: UIViewController {

    private var camera: AVCaptureDevice? = {
        let discoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInTelephotoCamera, .builtInWideAngleCamera],
                                                                mediaType: .video,
                                                                position: .front)
        return discoverySession.devices.first
    }()
    
    private var captureQueue: DispatchQueue = {
       return DispatchQueue(label: "captureQueue")
    }()
    
    private var captureSession: AVCaptureSession?
    
    private var detectionRequest: VNDetectFaceRectanglesRequest?
    
    private var videoWriter: EventVideoRecorder?
    
    private var isFaceDetected: Bool = false {
        didSet {
            checkToRecord()
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        if(!setupCaptureSession()) {
            return
        }
        
        setupPreview()
        setupVision()
        
        captureSession?.startRunning()
    }

    func setupCaptureSession() -> Bool {
        captureSession = AVCaptureSession()
        guard camera != nil else {
            return false
        }
        var deviceInput: AVCaptureDeviceInput!
        do {
            deviceInput = try AVCaptureDeviceInput(device: camera!)
        } catch {
            print(error)
            return false
        }
        
        captureSession?.addInput(deviceInput)
        let videoDataOutput = AVCaptureVideoDataOutput()
        videoDataOutput.setSampleBufferDelegate(self, queue: captureQueue)
        
        captureSession?.addOutput(videoDataOutput)
        
        return true
    }
    
    func setupPreview() {
        let previewView = PreviewView(frame: self.view.bounds)
        self.view.addSubview(previewView)
        previewView.videoPreviewLayer.session = captureSession
    }
    
    func setupVision() {
        
        detectionRequest = VNDetectFaceRectanglesRequest { (request, error) in
            if error != nil {
                
            }
            guard let faceDetectionRequest = request as? VNDetectFaceRectanglesRequest,
                let results = faceDetectionRequest.results as? [VNFaceObservation] else {
                    return
            }
            
            if(results.isEmpty) {
                self.isFaceDetected = false
                return
            }
            for result in results {
                if result.confidence > 0.7 {
                    self.isFaceDetected = true
                    return
                } else {
                    self.isFaceDetected = false
                }
            }
        }
    }
    
    func exifOrientationForCurrentDeviceOrientation() -> CGImagePropertyOrientation {
        return exifOrientationForDeviceOrientation(UIDevice.current.orientation)
    }
    
    func exifOrientationForDeviceOrientation(_ deviceOrientation: UIDeviceOrientation) -> CGImagePropertyOrientation {
        
        switch deviceOrientation {
        case .portraitUpsideDown:
            return .rightMirrored
            
        case .landscapeLeft:
            return .downMirrored
            
        case .landscapeRight:
            return .upMirrored
            
        default:
            return .leftMirrored
        }
    }
    
    func checkToRecord() {
        if(isFaceDetected) {
            guard let writer = self.videoWriter else {
                self.videoWriter = EventVideoRecorder()
                self.videoWriter?.delegate = self
                return
            }
        } else {
            guard let writer = self.videoWriter else {
                return
            }
            writer.saveFile()
        }
    }

}

extension ViewController: AVCaptureVideoDataOutputSampleBufferDelegate
{
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        
       
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        var requestHandlerOptions: [VNImageOption: AnyObject] = [:]
        
        let cameraIntrinsicData = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut: nil)
        if cameraIntrinsicData != nil {
            requestHandlerOptions[VNImageOption.cameraIntrinsics] = cameraIntrinsicData
        }
        
        let exifOrientation = self.exifOrientationForCurrentDeviceOrientation()
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            print("Failed to obtain a CVPixelBuffer for the current output frame.")
            return
        }
        
        let detectionRequestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                                            orientation: exifOrientation,
                                                            options: requestHandlerOptions)
        
        do {
            guard let request = self.detectionRequest else {
                return
            }
            try detectionRequestHandler.perform([request])
        } catch let error as NSError {
            NSLog("Failed to perform FaceRectangleRequest: %@", error)
        }
        
        if let writer = self.videoWriter {
            writer.appendSampleBuffer(buffer: pixelBuffer, timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        }
        
    }
}

extension ViewController: EventVideoRecorderDelegate {
    func eventVideoRecorderDidSavedVideo(_ recorder: EventVideoRecorder) {
        self.videoWriter = nil
    }
    
    func eventVideoRecorderNeedsLibraryPermission(_ recorder: EventVideoRecorder) {
        let ok = UIAlertAction(title: "OK", style: .default, handler: nil)
        let alert = UIAlertController(title: nil, message: "Please turn on permission for photo library", preferredStyle: .alert)
        alert.addAction(ok)
        present(alert, animated: true, completion: nil)
    }
    
    func eventVideoRecorderFailedToSavedVideo(_ recorder: EventVideoRecorder) {
        self.videoWriter = nil
    }
}

protocol EventVideoRecorderDelegate: class {
    func eventVideoRecorderDidSavedVideo(_ recorder: EventVideoRecorder)
    func eventVideoRecorderNeedsLibraryPermission(_ recorder: EventVideoRecorder)
    func eventVideoRecorderFailedToSavedVideo(_ recorder: EventVideoRecorder)
}

class EventVideoRecorder {

    private let writerInput: AVAssetWriterInput
    private let writer: AVAssetWriter
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let eventVideoTimeLimit: Float64 = 10

    private var startTime: CMTime?  // Not sure why duration of CMSampleBuffer is invalid, so use time calculation to get a rough value
    private(set) var hasData = false
    private var writingFinished = false

    weak var delegate: EventVideoRecorderDelegate?

    init() {
        let settings: [String : Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: NSNumber(value: Float(1920)),
            AVVideoHeightKey: NSNumber(value: Float(1080))
        ]
        writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        
        
        let filePath = NSTemporaryDirectory() + "tempVideo_\(Date().timeIntervalSince1970).mp4"
        if FileManager.default.fileExists(atPath: filePath) {
            try! FileManager.default.removeItem(atPath: filePath)
        }
        writer = try! AVAssetWriter(url: URL(fileURLWithPath: filePath), fileType: .mp4)
        writer.add(writerInput)
        writerInput.transform = EventVideoRecorder.getVideoTransform()
        
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: writerInput,
                                                       sourcePixelBufferAttributes: nil)
    }

    @discardableResult
    func appendSampleBuffer(buffer: CVPixelBuffer, timestamp: CMTime) -> Bool {
        guard !writingFinished else { return false }

        if startTime == nil {
            startTime = timestamp
            hasData =  true
            writer.startWriting()
            writer.startSession(atSourceTime: timestamp)
        }
        
        return adaptor.append(buffer, withPresentationTime: timestamp)
    }

    func saveFile() {
        guard hasData else {
            DispatchQueue.main.async {
                self.delegate?.eventVideoRecorderFailedToSavedVideo(self)
            }
            return
        }

        startTime = nil
        writingFinished = true

        writer.finishWriting {
            PHPhotoLibrary.requestAuthorization { (status) in
                if status == .authorized {
                    PHPhotoLibrary.shared().performChanges({
                        PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: self.writer.outputURL)
                    }) { (success, error) in
                        if let error = error {
                            print("\(error.localizedDescription)")
                            DispatchQueue.main.async {
                                self.delegate?.eventVideoRecorderFailedToSavedVideo(self)
                            }
                        } else {
                            print("Video has been exported to photo library.")
                            DispatchQueue.main.async {
                                self.delegate?.eventVideoRecorderDidSavedVideo(self)
                            }
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        self.delegate?.eventVideoRecorderNeedsLibraryPermission(self)
                    }
                }
            }
        }
    }
    
    private static func getVideoTransform() -> CGAffineTransform {
        switch UIDevice.current.orientation {
        case .portraitUpsideDown:
            return CGAffineTransform(rotationAngle: CGFloat((.pi * -90.0)) / 180.0)
        case .landscapeLeft:
            return CGAffineTransform(rotationAngle: CGFloat((.pi * -180.0)) / 180.0) // TODO: Add support for front facing camera
//            return CGAffineTransform(rotationAngle: CGFloat((M_PI * 0.0)) / 180.0) // TODO: For front facing camera
        case .landscapeRight:
            return CGAffineTransform(rotationAngle: CGFloat((.pi * 0.0)) / 180.0) // TODO: Add support for front facing camera
//            return CGAffineTransform(rotationAngle: CGFloat((M_PI * -180.0)) / 180.0) // TODO: For front facing camera
        default:
            return CGAffineTransform(rotationAngle: CGFloat((.pi * 90.0)) / 180.0)
        }
    }
    
}
