import CoreImage
import AppKit

/// Content-aware page inversion for dark reading.
///
/// A naïve `CIColorInvert` turns white pages dark — but it also turns colour
/// photos into ugly negatives. Ream's dark-content mode inverts the *paper and
/// text* while leaving colour images untouched, using a chroma mask:
///
/// 1. `inverted` = full colour-invert of the page.
/// 2. `chroma`   = per-pixel `max(r,g,b) − min(r,g,b)` (0 for greys, high for
///    saturated colour), computed with `CIMaximumComponent` /
///    `CIMinimumComponent` and a difference blend.
/// 3. The chroma image, sharpened and clamped, is used as a blend mask:
///    saturated pixels (photos, coloured logos) keep the **original**; near-grey
///    pixels (body text, line art, the page background) take the **inverted**
///    version.
///
/// Known limitation: a *greyscale* photograph has near-zero chroma and will
/// invert like text. Colour photos — the common case — are preserved. iOS Smart
/// Invert makes the same trade-off.
enum DarkContentInverter {

    /// Shared Metal-backed context. Building a `CIContext` is expensive, so we
    /// keep one for the whole app; it is internally thread-safe.
    static let ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()

    /// CPU fallback context. Some environments (headless test runners, machines
    /// without an available GPU session) can create a Metal context whose
    /// `createCGImage` nonetheless fails; we fall back to a software context so
    /// inversion still produces pixels everywhere.
    private static let softwareContext = CIContext(options: [
        .useSoftwareRenderer: true,
        .cacheIntermediates: false
    ])

    /// Invert `input` and rasterize the result to a `CGImage`, using the fast
    /// Metal context when it works and the software context otherwise. Returns
    /// `nil` only if both rasterizers fail.
    static func render(_ input: CIImage) -> CGImage? {
        let output = invert(input)
        if let image = ciContext.createCGImage(output, from: input.extent) {
            return image
        }
        return softwareContext.createCGImage(output, from: input.extent)
    }

    /// Apply the content-aware inversion to a CoreImage image, returning the
    /// filtered image (same extent).
    static func invert(_ input: CIImage) -> CIImage {
        // 1. Full invert.
        guard let invertFilter = CIFilter(name: "CIColorInvert") else { return input }
        invertFilter.setValue(input, forKey: kCIInputImageKey)
        let inverted = invertFilter.outputImage ?? input

        // 2. Chroma = max component − min component.
        guard let maxFilter = CIFilter(name: "CIMaximumComponent"),
              let minFilter = CIFilter(name: "CIMinimumComponent") else { return inverted }
        maxFilter.setValue(input, forKey: kCIInputImageKey)
        minFilter.setValue(input, forKey: kCIInputImageKey)
        guard let maxImage = maxFilter.outputImage,
              let minImage = minFilter.outputImage,
              let diff = CIFilter(name: "CIDifferenceBlendMode") else { return inverted }
        diff.setValue(maxImage, forKey: kCIInputImageKey)
        diff.setValue(minImage, forKey: kCIInputBackgroundImageKey)
        guard var chroma = diff.outputImage else { return inverted }

        // 3. Sharpen the mask: scale chroma up so even modestly-coloured pixels
        //    (photos) fully preserve, then clamp to [0,1]. Antialiased text edges
        //    carry a little colour; the clamp keeps them on the inverted side.
        if let scale = CIFilter(name: "CIColorMatrix") {
            let k: CGFloat = 4.0
            scale.setValue(chroma, forKey: kCIInputImageKey)
            scale.setValue(CIVector(x: k, y: 0, z: 0, w: 0), forKey: "inputRVector")
            scale.setValue(CIVector(x: 0, y: k, z: 0, w: 0), forKey: "inputGVector")
            scale.setValue(CIVector(x: 0, y: 0, z: k, w: 0), forKey: "inputBVector")
            scale.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
            if let scaled = scale.outputImage { chroma = scaled }
        }
        if let clamp = CIFilter(name: "CIColorClamp") {
            clamp.setValue(chroma, forKey: kCIInputImageKey)
            if let clamped = clamp.outputImage { chroma = clamped }
        }

        // 4. Blend: original where mask (chroma) is white, inverted where black.
        guard let blend = CIFilter(name: "CIBlendWithMask") else { return inverted }
        blend.setValue(input, forKey: kCIInputImageKey)              // colourful → keep
        blend.setValue(inverted, forKey: kCIInputBackgroundImageKey) // grey → invert
        blend.setValue(chroma, forKey: kCIInputMaskImageKey)
        return blend.outputImage ?? inverted
    }
}
