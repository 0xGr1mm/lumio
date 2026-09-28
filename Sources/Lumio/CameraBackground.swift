import CoreImage
import Vision

/// Separates the person in a camera frame from what is behind them, so the background can be blurred or removed.
/// Vision runs on device; masks are cached per frame size and reused while the compositor asks for the same picture.
final class PersonMaskMaker: @unchecked Sendable {
    /// Vision's own mask is small; it is scaled up to the camera frame, which also softens its edge.
    private let lock = NSLock()
    private var cached: (fingerprint:String,mask:CIImage?)?
    private let context = CIContext(options:[.cacheIntermediates:false])
    private let quality: VNGeneratePersonSegmentationRequest.QualityLevel

    init(quality:VNGeneratePersonSegmentationRequest.QualityLevel = .balanced) { self.quality = quality }

    /// A white-on-black mask covering the person, in the image's own coordinates, or nil when nobody is found.
    func mask(for image:CIImage,fingerprint:String)->CIImage? {
        lock.lock()
        if let cached, cached.fingerprint == fingerprint { let mask=cached.mask;lock.unlock();return mask }
        lock.unlock()
        let mask = makeMask(for:image)
        lock.lock(); cached=(fingerprint,mask); lock.unlock()
        return mask
    }
    /// Fraction of the mask that is part of the person, 0…1.
    private func coverage(of mask:CIImage)->Double {
        guard let average=CIFilter(name:"CIAreaAverage",parameters:[kCIInputImageKey:mask,kCIInputExtentKey:CIVector(cgRect:mask.extent)])?.outputImage else { return 0 }
        var pixel=[UInt8](repeating:0,count:4)
        context.render(average,toBitmap:&pixel,rowBytes:4,bounds:CGRect(x:0,y:0,width:1,height:1),format:.RGBA8,colorSpace:nil)
        return Double(pixel[0])/255
    }
    private func makeMask(for image:CIImage)->CIImage? {
        let extent = image.extent
        guard extent.width >= 32, extent.height >= 32, extent.width.isFinite, extent.height.isFinite else { return nil }
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = quality
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(ciImage:image,options:[:])
        do { try handler.perform([request]) } catch { return nil }
        guard let buffer = request.results?.first?.pixelBuffer else { return nil }
        let raw = CIImage(cvPixelBuffer:buffer)
        guard raw.extent.width > 0, raw.extent.height > 0 else { return nil }
        // Vision answers with an empty mask rather than nothing when nobody is in view;
        // treating that as a person would blur or erase the whole picture.
        guard coverage(of:raw) > 0.015 else { return nil }
        let scale = CGAffineTransform(scaleX:extent.width/raw.extent.width,y:extent.height/raw.extent.height)
        return raw.transformed(by:scale).transformed(by:CGAffineTransform(translationX:extent.minX,y:extent.minY))
    }
}

/// Applies the camera background treatment to one frame. Without a person in view the frame is returned untouched,
/// so a camera pointed at an empty room never loses its picture.
func cameraWithTreatedBackground(_ image:CIImage,style:CameraStyle,masks:PersonMaskMaker?,fingerprint:String)->CIImage {
    let treatment = style.resolvedBackground
    guard treatment != "None", let masks, let mask=masks.mask(for:image,fingerprint:fingerprint) else { return image }
    let extent = image.extent
    switch treatment {
    case "Blur":
        let radius = max(2,style.resolvedBackgroundBlur*extent.height/240)
        let blurred = image.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:radius]).cropped(to:extent)
        return image.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:blurred,kCIInputMaskImageKey:mask]).cropped(to:extent)
    default:
        let clear = CIImage(color:.clear).cropped(to:extent)
        return image.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:clear,kCIInputMaskImageKey:mask]).cropped(to:extent)
    }
}
