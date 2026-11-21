import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct FrameOptions: Sendable {
    public var device: String?
    public var color: String?
    public var defaultColors: [String: String]
    public var strictColor: Bool

    public init(device: String? = nil, color: String? = nil,
                defaultColors: [String: String] = [:], strictColor: Bool = false) {
        self.device = device
        self.color = color
        self.defaultColors = defaultColors
        self.strictColor = strictColor
    }
}

public struct FrameDescription: Sendable {
    public let match: DeviceMatch
    public let color: String?
    public let inputSize: PixelSize
    public let frameSize: PixelSize
    public let resizeTarget: PixelSize?
    public let maskMissing: Bool

    public var hasAppliedMask: Bool { match.device.hasMask && !maskMissing }
}

public struct FramedImage: Sendable {
    public let image: CGImage
    public let description: FrameDescription
}

public struct ImageComposition: Sendable {
    public let image: CGImage
    public let scaleFactors: [Double]
}

struct RenderPlan {
    let description: FrameDescription
    let frame: CIImage
    let mask: CIImage?
    let warp: WarpPlan?
}

struct WarpPlan {
    struct Region {
        let coefficients: [Double]
        let polygon: CIImage
        let bounds: CGRect
        let detail: PixelSize
    }

    let regions: [Region]
    let reflection: CIImage?
    let cameraLayers: [(image: CIImage, levels: [Int])]
    let screenBlend: Bool
}

public struct FramesRenderer: Sendable {
    public let catalog: FrameCatalog
    private let context: CIContext

    public init(catalog: FrameCatalog) {
        self.catalog = catalog
        context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    }

    public static func imageSize(at url: URL) throws -> PixelSize {
        let source = try imageSource(url)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw FramesError("Could not read image dimensions at \(url.path).")
        }
        let size = PixelSize(width: width, height: height)
        try size.validate()
        return size
    }

    public func frameImage(at url: URL, options: FrameOptions = .init()) throws -> FramedImage {
        try frameImage(Self.readImage(url), options: options)
    }

    public func frameImage(_ image: CGImage, options: FrameOptions = .init()) throws -> FramedImage {
        let size = PixelSize(width: image.width, height: image.height)
        let description = try describeFrame(size, options: options)
        let plan = try prepare(description)
        // A flat mask replaces input alpha. Keep the RGB channels of straight-alpha pixels.
        let source = plan.mask != nil && plan.warp == nil && description.resizeTarget == nil
            ? Self.ignoringStraightAlpha(of: image) : image
        let result = try composite(CIImage(cgImage: source), plan: plan)
        return FramedImage(image: try makeImage(result), description: plan.description)
    }

    public func composeImages(_ frames: [FramedImage], spacing: Int = 60,
                              proportional: Bool = true) throws -> ImageComposition {
        let images = frames.map { CIImage(cgImage: $0.image) }
        let arrangement = try layout(images, physicalHeights: frames.map { $0.description.match.device.physicalHeight },
                                     spacing: spacing, proportional: proportional, bottomAlign: false)
        let image = try makeImage(merge(images, layout: arrangement, background: nil))
        let factors = zip(arrangement.placements, frames).map { placement, frame in
            Double(placement.size.height) / Double(frame.image.height)
        }
        return ImageComposition(image: image, scaleFactors: factors)
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw FramesError("Could not create PNG encoder.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw FramesError("Could not encode PNG.") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (data as Data).write(to: url, options: .atomic)
    }

    private static func imageSource(_ url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw FramesError("Could not read image at \(url.path).")
        }
        return source
    }

    static func readImage(_ url: URL) throws -> CGImage {
        _ = try imageSize(at: url)
        guard let image = CGImageSourceCreateImageAtIndex(try imageSource(url), 0, nil) else {
            throw FramesError("Could not decode image at \(url.path).")
        }
        return image
    }

    private static func ignoringStraightAlpha(of image: CGImage) -> CGImage {
        let alpha: CGImageAlphaInfo
        switch image.alphaInfo {
        case .first: alpha = .noneSkipFirst
        case .last: alpha = .noneSkipLast
        default: return image
        }
        guard let colorSpace = image.colorSpace, let provider = image.dataProvider else { return image }
        let bitmapInfo = image.bitmapInfo.subtracting(.alphaInfoMask).union(CGBitmapInfo(rawValue: alpha.rawValue))
        return CGImage(width: image.width, height: image.height, bitsPerComponent: image.bitsPerComponent,
                       bitsPerPixel: image.bitsPerPixel, bytesPerRow: image.bytesPerRow, space: colorSpace,
                       bitmapInfo: bitmapInfo, provider: provider, decode: nil,
                       shouldInterpolate: image.shouldInterpolate, intent: image.renderingIntent) ?? image
    }

    func makeImage(_ image: CIImage) throws -> CGImage {
        guard let rendered = context.createCGImage(image, from: image.extent, format: .RGBA8,
                                                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
            throw FramesError("Could not render \(image.extent.size) image.")
        }
        return rendered
    }

    func describeFrame(_ size: PixelSize, options: FrameOptions, videoDisplaySize: PixelSize? = nil) throws -> FrameDescription {
        try size.validate()
        let match = try catalog.resolve(size, device: options.device)
        let device = match.device
        let color = try catalog.color(for: device, selection: options.color,
                                      defaults: options.defaultColors, strict: options.strictColor)
        let frameURL = catalog.frameURL(device: device, color: color)
        let stored = try Self.imageSize(at: frameURL)
        let frameSize = device.name.hasSuffix(" Landscape") && stored.height > stored.width
            ? PixelSize(width: stored.height, height: stored.width) : stored
        let maskURL = catalog.accessoryURL(device: device, suffix: "mask")
        let hasMaskAsset = FileManager.default.fileExists(atPath: maskURL.path)
        let target = device.resizeTarget(for: size)
        try target?.validate()
        if let warp = device.warp {
            guard warp.accepts(videoDisplaySize ?? size, scaled: videoDisplaySize != nil) else {
                let expected = warp.inputSizes.map { $0.map(String.init).joined(separator: "x") }.joined(separator: " or ")
                let input = videoDisplaySize == nil ? "screenshot" : "recording"
                throw FramesError("\(device.name) requires an iPhone Duo inner \(input) (\(expected)).")
            }
            guard hasMaskAsset else { throw FramesError("Display mask missing for \(device.name).") }
            if warp.camera != nil, !FileManager.default.fileExists(atPath: catalog.accessoryURL(device: device, suffix: "camera").path) {
                throw FramesError("Camera layers missing for \(device.name).")
            }
        }
        return FrameDescription(match: match, color: color, inputSize: size, frameSize: frameSize, resizeTarget: target,
                                maskMissing: device.hasMask && !hasMaskAsset)
    }

    func prepare(_ description: FrameDescription, displaySize: PixelSize? = nil) throws -> RenderPlan {
        let device = description.match.device
        let frameURL = catalog.frameURL(device: device, color: description.color)
        let raw = try Self.readImage(frameURL)
        let frame = rotateSideways(CIImage(cgImage: raw), for: device)
        let maskURL = catalog.accessoryURL(device: device, suffix: "mask")
        let mask: CIImage?
        if (device.hasMask || device.warp != nil) && !description.maskMissing {
            let accessory = try Self.readImage(maskURL)
            mask = rotateSideways(CIImage(cgImage: accessory, options: [.colorSpace: NSNull()]), for: device)
        } else {
            mask = nil
        }
        let warp: WarpPlan?
        if let spec = device.warp {
            guard let mask, mask.extent.size == frame.extent.size else {
                throw FramesError("Invalid display mask for \(device.name).")
            }
            warp = try prepareWarp(spec, frame: description.frameSize, source: displaySize ?? description.inputSize,
                                   color: description.color, device: device)
        } else {
            warp = nil
        }
        return RenderPlan(description: description, frame: frame, mask: mask, warp: warp)
    }

    private func rotateSideways(_ image: CIImage, for device: FrameDevice) -> CIImage {
        if device.name.hasSuffix(" Landscape"), image.extent.height > image.extent.width {
            return image.oriented(.left)
        }
        return image
    }

    func sized(_ image: CIImage, width: Int, height: Int) -> CIImage {
        if image.extent.width == CGFloat(width), image.extent.height == CGFloat(height) { return image }
        let vertical = Double(height) / image.extent.height
        let horizontal = Double(width) / image.extent.width
        return image.clampedToExtent().applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: vertical,
            kCIInputAspectRatioKey: horizontal / vertical,
        ]).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    func composite(_ screenshot: CIImage, plan: RenderPlan) throws -> CIImage {
        if let warp = plan.warp, let mask = plan.mask {
            return try compositeWarped(screenshot, plan: plan, warp: warp, mask: mask)
        }
        let device = plan.description.match.device
        let target = plan.description.resizeTarget
            ?? PixelSize(width: Int(screenshot.extent.width), height: Int(screenshot.extent.height))
        var source = sized(screenshot, width: target.width, height: target.height)
        if let mask = plan.mask {
            let scaled = sized(mask, width: target.width, height: target.height)
            source = try applyKernel(RenderKernels.replaceAlpha, extent: source.extent, arguments: [source, scaled])
        }
        source = source.transformed(by: CGAffineTransform(
            translationX: CGFloat(device.x), y: plan.frame.extent.height - CGFloat(device.y) - source.extent.height
        ))
        return plan.frame.composited(over: source).cropped(to: plan.frame.extent)
    }

    private func prepareWarp(_ warp: Warp, frame: PixelSize, source: PixelSize,
                             color: String?, device: FrameDevice) throws -> WarpPlan {
        let scale = 2.0
        let canvasHeight = Double(frame.height) * scale
        let canvas = CGRect(x: 0, y: 0, width: Double(frame.width) * scale, height: canvasHeight)
        guard !warp.regions.isEmpty else { throw FramesError("Missing projection regions for \(device.name).") }
        let regions = try warp.regions.map { region in
            guard region.inverse.count == 8, region.inverse.allSatisfy(\.isFinite),
                  region.polygon.count >= 3, region.polygon.allSatisfy({ $0.count == 2 && $0.allSatisfy { $0.isFinite } }) else {
                throw FramesError("Invalid projection region for \(device.name).")
            }
            let points = region.polygon.map { CGPoint(x: $0[0] * scale, y: canvasHeight - $0[1] * scale) }
            let path = CGMutablePath()
            path.addLines(between: points)
            path.closeSubpath()
            let bounds = path.boundingBox.integral.intersection(canvas)
            guard !bounds.isEmpty,
                  let drawing = CGContext(data: nil, width: Int(bounds.width), height: Int(bounds.height),
                                          bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                throw FramesError("Could not make the projection mask for \(device.name).")
            }
            drawing.translateBy(x: -bounds.minX, y: -bounds.minY)
            drawing.setShouldAntialias(false)
            drawing.setFillColor(gray: 1, alpha: 1)
            drawing.addPath(path)
            drawing.fillPath()
            guard let mask = drawing.makeImage() else { throw FramesError("Could not draw projection mask.") }
            let clip = CIImage(cgImage: mask, options: [.colorSpace: NSNull()])
                .transformed(by: CGAffineTransform(translationX: bounds.minX, y: bounds.minY))
            var detail = source
            if let extent = region.extent, extent.count == 2, extent.allSatisfy({ $0.isFinite && $0 > 0 }) {
                detail = PixelSize(width: Int(min(Double(source.width), ceil(extent[0]))),
                                   height: Int(min(Double(source.height), ceil(extent[1]))))
            }
            return WarpPlan.Region(coefficients: region.inverse, polygon: clip, bounds: bounds, detail: detail)
        }

        var reflection: CIImage?
        if let color, let levels = warp.reflections?[color], !levels.isEmpty,
           let bytes = CGDataProvider(data: Data(levels) as CFData) {
            let vertical = warp.reflectionAxis == "y"
            let span = warp.reflectionSpan ?? [0, Double(levels.count)]
            guard span.count == 2, span[0] >= 0, span[1] > span[0], span[1] <= Double(levels.count),
                  let strip = CGImage(width: vertical ? 1 : levels.count, height: vertical ? levels.count : 1,
                                      bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: vertical ? 1 : levels.count,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [], provider: bytes,
                                      decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
                throw FramesError("Invalid reflection profile for \(device.name).")
            }
            let source = CIImage(cgImage: strip, options: [.colorSpace: NSNull()])
            let start = vertical ? Double(levels.count) - span[1] : span[0]
            let shifted = source.transformed(by: .init(translationX: vertical ? 0 : -start, y: vertical ? -start : 0))
            let length = span[1] - span[0]
            let transform = CGAffineTransform(scaleX: Double(frame.width) / (vertical ? 1 : length),
                                              y: Double(frame.height) / (vertical ? length : 1))
            reflection = shifted.clampedToExtent().transformed(by: transform)
                .cropped(to: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        }

        var cameras: [(CIImage, [Int])] = []
        if let camera = warp.camera {
            let strip = try Self.readImage(catalog.accessoryURL(device: device, suffix: "camera"))
            guard !camera.blendIf.isEmpty, strip.width.isMultiple(of: camera.blendIf.count),
                  camera.blendIf.allSatisfy({ $0.count == 4 && $0.allSatisfy { (0...255).contains($0) } && $0 == $0.sorted() }),
                  (0...frame.width).contains(camera.x), (0...frame.height).contains(camera.y) else {
                throw FramesError("Invalid camera layers for \(device.name).")
            }
            let width = strip.width / camera.blendIf.count
            let y = frame.height - camera.y - strip.height
            let image = CIImage(cgImage: strip)
            cameras = camera.blendIf.enumerated().map { index, levels in
                let x = index * width
                let layer = image.cropped(to: CGRect(x: x, y: 0, width: width, height: strip.height))
                    .transformed(by: .init(translationX: CGFloat(camera.x - x), y: CGFloat(y)))
                return (layer, levels)
            }
        }
        return WarpPlan(regions: regions, reflection: reflection, cameraLayers: cameras,
                        screenBlend: (warp.blend ?? "screen") == "screen")
    }

    private func compositeWarped(_ screenshot: CIImage, plan: RenderPlan,
                                 warp: WarpPlan, mask: CIImage) throws -> CIImage {
        let size = plan.description.frameSize
        let height = Double(size.height) * 2
        let supersampled = CGRect(x: 0, y: 0, width: size.width * 2, height: size.height * 2)
        var display = CIImage(color: .clear).cropped(to: supersampled)
        guard let projection = RenderKernels.projection else { throw FramesError("Could not load the projection kernel.") }
        for region in warp.regions {
            let coefficients = region.coefficients
            let source = sized(screenshot, width: region.detail.width, height: region.detail.height)
            let first = CIVector(x: coefficients[0], y: coefficients[1], z: coefficients[2])
            let second = CIVector(x: coefficients[3], y: coefficients[4], z: coefficients[5])
            let third = CIVector(x: coefficients[6], y: coefficients[7], z: height)
            let dimensions = CIVector(x: Double(region.detail.width), y: Double(region.detail.height))
            guard let projected = projection.apply(extent: region.bounds, roiCallback: { _, _ in source.extent },
                                                   image: source, arguments: [first, second, third, dimensions]) else {
                throw FramesError("Could not project screenshot.")
            }
            display = projected.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: display,
                kCIInputMaskImageKey: region.polygon,
            ]).cropped(to: supersampled)
        }
        display = sized(display, width: size.width, height: size.height)
        let reflection = warp.reflection ?? CIImage(color: .black).cropped(to: plan.frame.extent)
        var result = try applyKernel(RenderKernels.warpBlend, extent: plan.frame.extent,
                                     arguments: [display, plan.frame, mask, reflection, warp.screenBlend ? 1.0 : 0.0])
        for (layer, levels) in warp.cameraLayers {
            let range = CIVector(x: Double(levels[0]), y: Double(levels[1]), z: Double(levels[2]), w: Double(levels[3]))
            let camera = try applyKernel(RenderKernels.camera, extent: layer.extent, arguments: [layer, result, range])
            result = camera.composited(over: result)
        }
        return result.cropped(to: plan.frame.extent)
    }

    private func applyKernel(_ kernel: CIColorKernel?, extent: CGRect, arguments: [Any]) throws -> CIImage {
        guard let result = kernel?.apply(extent: extent, arguments: arguments) else {
            throw FramesError("Could not apply the compositing kernel.")
        }
        return result
    }

    struct Placement {
        let x: Int
        let top: Int
        let size: PixelSize
    }

    struct Layout {
        let size: PixelSize
        let placements: [Placement]
    }

    func layout(_ images: [CIImage], physicalHeights: [Double], spacing: Int,
                proportional: Bool, bottomAlign: Bool) throws -> Layout {
        guard !images.isEmpty, images.count == physicalHeights.count, (0...50_000).contains(spacing) else {
            throw FramesError("Expected one or more frames and nonnegative spacing within the canvas limit.")
        }
        let sizes = images.map { PixelSize(width: Int($0.extent.width), height: Int($0.extent.height)) }
        let scale = proportional && physicalHeights.allSatisfy { $0 > 0 } && Set(physicalHeights).count > 1
        let bodies = try images.map { image in
            if scale { return try bodyRows(image) }
            return 0..<Int(image.extent.height)
        }
        var factors = Array(repeating: 1.0, count: images.count)
        if scale {
            let densities = zip(bodies, physicalHeights).map { Double($0.count) / $1 }
            guard let reference = densities.min(), reference > 0, densities.allSatisfy(\.isFinite) else {
                throw FramesError("Invalid physical height in the device catalog.")
            }
            factors = densities.map { reference / $0 }
        }
        let output = zip(sizes, factors).map { size, factor in
            let factor = factor >= 0.999 ? 1 : factor
            return PixelSize(width: max(1, Int((Double(size.width) * factor).rounded(.toNearestOrEven))),
                             height: max(1, Int((Double(size.height) * factor).rounded(.toNearestOrEven))))
        }
        let bottoms = bodies.indices.map { i in
            Int((Double(bodies[i].upperBound) * Double(output[i].height) / Double(sizes[i].height)).rounded(.toNearestOrEven))
        }
        let line = bottoms.max() ?? 0
        var x = 0
        let placements = output.indices.map { i in
            let offset = line - bottoms[i]
            let placement = Placement(x: x, top: scale || bottomAlign ? offset : offset / 2, size: output[i])
            x += output[i].width + spacing
            return placement
        }
        let size = PixelSize(width: x - spacing, height: placements.map { $0.top + $0.size.height }.max() ?? 0)
        try size.validate()
        return Layout(size: size, placements: placements)
    }

    private func bodyRows(_ image: CIImage) throws -> Range<Int> {
        let width = Int(image.extent.width)
        let height = Int(image.extent.height)
        var bytes = [UInt8](repeating: 0, count: width * height)
        bytes.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width, bounds: image.extent,
                           format: .A8, colorSpace: nil)
        }
        var bottom = height
        var top = 0
        for (index, value) in bytes.enumerated() where value != 0 {
            bottom = min(bottom, index / width)
            top = max(top, index / width + 1)
        }
        return bottom < top ? (height - top)..<(height - bottom) : 0..<height
    }

    func merge(_ images: [CIImage], layout: Layout, background: CIColor?) -> CIImage {
        let canvas = CGRect(x: 0, y: 0, width: layout.size.width, height: layout.size.height)
        var result = CIImage(color: background ?? .clear).cropped(to: canvas)
        for (image, placement) in zip(images, layout.placements) {
            let translated = sized(image, width: placement.size.width, height: placement.size.height).transformed(by: .init(
                translationX: CGFloat(placement.x), y: CGFloat(layout.size.height - placement.top - placement.size.height)
            ))
            result = translated.composited(over: result)
        }
        return result.cropped(to: canvas)
    }

    func render(_ image: CIImage, to buffer: CVPixelBuffer, bounds: CGRect) {
        context.render(image, to: buffer, bounds: bounds, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }
}

private enum RenderKernels {
    static let replaceAlpha = CIColorKernel(source: """
        kernel vec4 replaceAlpha(__sample image, __sample mask) {
            return vec4(unpremultiply(image).rgb * mask.r, mask.r);
        }
        """)

    static let projection = CIWarpKernel(source: """
        kernel vec2 project(vec3 u, vec3 v, vec3 q, vec2 dimensions) {
            vec2 p = vec2(destCoord().x, q.z - destCoord().y) * 0.5;
            float scale = dot(q.xy, p) + 1.0;
            vec3 point = vec3(p, 1.0);
            return vec2(dot(u, point) / scale, 1.0 - dot(v, point) / scale) * dimensions;
        }
        """)

    static let warpBlend = CIColorKernel(source: """
        kernel vec4 mixDisplay(__sample display, __sample frame, __sample mask,
                               __sample reflection, float screenBlend) {
            vec3 hardware = unpremultiply(frame).rgb;
            vec3 source = unpremultiply(display).rgb;
            vec3 screened = 1.0 - (1.0 - hardware) * (1.0 - source);
            vec3 light = min(mix(source, screened, screenBlend) + reflection.rgb, 1.0);
            return vec4(mix(hardware, light, display.a * mask.r) * frame.a, frame.a);
        }
        """)

    static let camera = CIColorKernel(source: """
        kernel vec4 camera(__sample layer, __sample display, vec4 limits) {
            float gray = dot(unpremultiply(display).rgb, vec3(0.299, 0.587, 0.114)) * 255.0;
            float up = clamp((gray - limits.x) / max(limits.y - limits.x, 0.001), 0.0, 1.0);
            float down = clamp((limits.w - gray) / max(limits.w - limits.z, 0.001), 0.0, 1.0);
            return layer * (gray >= limits.y && gray <= limits.z ? 1.0 : min(up, down));
        }
        """)
}
