
import AVFoundation
import Metal

public protocol MetalCameraSessionDelegate {
    /**
     Camera session did receive a new frame and converted it to an array of Metal textures. For instance, if the RGB pixel format was selected, the array will have a single texture, whereas if YCbCr was selected, then there will be two textures: the Y texture at index 0, and CbCr texture at index 1 (following the order in a sample buffer).
     
     - parameter session:                   Session that triggered the update
     - parameter didReceiveFrameAsTextures: Frame converted to an array of Metal textures
     - parameter withTimestamp:             Frame timestamp in seconds
     */
    func metalCameraSession(_ session: MetalCameraSession, didReceiveFrameAsTextures: [MTLTexture], withTimestamp: Double)
    
    /**
     Camera session did update capture state
     
     - parameter session:        Session that triggered the update
     - parameter didUpdateState: Capture session state
     - parameter error:          Capture session error or `nil`
     */
    func metalCameraSession(_ session: MetalCameraSession, didUpdateState: MetalCameraSessionState, error: MetalCameraSessionError?)
}

public final class MetalCameraSession: NSObject {
    /// Delegate that will be notified about state changes and new frames
    public var delegate: MetalCameraSessionDelegate?
    
    /// Pixel format to be used for grabbing camera data and converting textures
    public let pixelFormat: MetalCameraPixelFormat
    
    /// Texture cache we will use for converting frame images to textures
    internal var textureCache: CVMetalTextureCache?
    
    /// `MTLDevice` we need to initialize texture cache
    fileprivate var metalDevice = MTLCreateSystemDefaultDevice()
    
    public init(pixelFormat: MetalCameraPixelFormat = .rgb, delegate: MetalCameraSessionDelegate? = nil) {
        self.pixelFormat = pixelFormat
        self.delegate = delegate
        super.init();
    }
    
    public func start() {
        do {
            try self.initializeTextureCache()
        }
        catch let error as MetalCameraSessionError {
            print("Error From Metal Start \(error)")
        }
        catch {
        }
    }
    
    public func initializeTextureCache() throws {
        #if arch(i386) || arch(x86_64)
        throw MetalCameraSessionError.failedToCreateTextureCache
        #else
        guard
            let metalDevice = metalDevice,
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, metalDevice, nil, &textureCache) == kCVReturnSuccess
        else {
            throw MetalCameraSessionError.failedToCreateTextureCache
        }
        #endif
    }
}

extension MetalCameraSession {
    
    private func texture(sampleBuffer: CMSampleBuffer?, textureCache: CVMetalTextureCache?, planeIndex: Int = 0, pixelFormat: MTLPixelFormat = .bgra8Unorm) throws -> MTLTexture {
        guard let sampleBuffer = sampleBuffer else {
            throw MetalCameraSessionError.missingSampleBuffer
        }
        guard let textureCache = textureCache else {
            throw MetalCameraSessionError.failedToCreateTextureCache
        }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw MetalCameraSessionError.failedToGetImageBuffer
        }
        
        let isPlanar = CVPixelBufferIsPlanar(imageBuffer)
        let width = isPlanar ? CVPixelBufferGetWidthOfPlane(imageBuffer, planeIndex) : CVPixelBufferGetWidth(imageBuffer)
        let height = isPlanar ? CVPixelBufferGetHeightOfPlane(imageBuffer, planeIndex) : CVPixelBufferGetHeight(imageBuffer)
        
        var imageTexture: CVMetalTexture?
        
        let result = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, imageBuffer, nil, pixelFormat, width, height, planeIndex, &imageTexture)
        
        guard
            let unwrappedImageTexture = imageTexture,
            let texture = CVMetalTextureGetTexture(unwrappedImageTexture),
            result == kCVReturnSuccess
        else {
            throw MetalCameraSessionError.failedToCreateTextureFromImage
        }
        
        return texture
    }
    
    private func timestamp(sampleBuffer: CMSampleBuffer?) throws -> Double {
        guard let sampleBuffer = sampleBuffer else {
            throw MetalCameraSessionError.missingSampleBuffer
        }
        
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        guard time != CMTime.invalid else {
            throw MetalCameraSessionError.failedToRetrieveTimestamp
        }
        
        return (Double)(time.value) / (Double)(time.timescale);
    }
    
    public func captureOutput(_ captureOutput: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        do {
            var textures: [MTLTexture]!
            
            switch pixelFormat {
            case .rgb:
                let textureRGB = try texture(sampleBuffer: sampleBuffer, textureCache: textureCache)
                textures = [textureRGB]
            case .yCbCr:
                let textureY = try texture(sampleBuffer: sampleBuffer, textureCache: textureCache, planeIndex: 0, pixelFormat: .r8Unorm)
                let textureCbCr = try texture(sampleBuffer: sampleBuffer, textureCache: textureCache, planeIndex: 1, pixelFormat: .rg8Unorm)
                textures = [textureY, textureCbCr]
            }
            
            let timestamp = try self.timestamp(sampleBuffer: sampleBuffer)
            
            delegate?.metalCameraSession(self, didReceiveFrameAsTextures: textures, withTimestamp: timestamp)
        }
        catch let error as MetalCameraSessionError {
            print("Error from Metal CaptureOutput \(error)")
        }
        catch {
            
        }
    }
    
}

public enum MetalCameraSessionState {
    case ready
    case streaming
    case stopped
    case waiting
    case error
}

public enum MetalCameraSessionError: Error {
    /**
     * Streaming errors
     *///
    case noHardwareAccess
    case failedToAddCaptureInputDevice
    case failedToAddCaptureOutput
    case requestedHardwareNotFound
    case inputDeviceNotAvailable
    case captureSessionRuntimeError
    
    /**
     * Conversion errors
     *///
    case failedToCreateTextureCache
    case missingSampleBuffer
    case failedToGetImageBuffer
    case failedToCreateTextureFromImage
    case failedToRetrieveTimestamp
    
    /**
     Indicates if the error is related to streaming the media.
     
     - returns: True if the error is related to streaming, false otherwise
     */
    public func isStreamingError() -> Bool {
        switch self {
        case .noHardwareAccess, .failedToAddCaptureInputDevice, .failedToAddCaptureOutput, .requestedHardwareNotFound, .inputDeviceNotAvailable, .captureSessionRuntimeError:
            return true
        default:
            return false
        }
    }
    
    public var localizedDescription: String {
        switch self {
        case .noHardwareAccess:
            return "Failed to get access to the hardware for a given media type"
        case .failedToAddCaptureInputDevice:
            return "Failed to add a capture input device to the capture session"
        case .failedToAddCaptureOutput:
            return "Failed to add a capture output data channel to the capture session"
        case .requestedHardwareNotFound:
            return "Specified hardware is not available on this device"
        case .inputDeviceNotAvailable:
            return "Capture input device cannot be opened, probably because it is no longer available or because it is in use"
        case .captureSessionRuntimeError:
            return "AVCaptureSession runtime error"
        case .failedToCreateTextureCache:
            return "Failed to initialize texture cache"
        case .missingSampleBuffer:
            return "No sample buffer to convert the image from"
        case .failedToGetImageBuffer:
            return "Failed to retrieve an image buffer from camera's output sample buffer"
        case .failedToCreateTextureFromImage:
            return "Failed to convert the frame to a Metal texture"
        case .failedToRetrieveTimestamp:
            return "Failed to retrieve timestamp from the sample buffer"
        }
    }
}

public enum MetalCameraPixelFormat {
    case rgb
    case yCbCr
    
    var coreVideoType: OSType {
        switch self {
        case .rgb:
            return kCVPixelFormatType_32BGRA
        case .yCbCr:
            return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
    }
}
