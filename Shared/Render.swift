#if os(macOS)
import AppKit
#else
import UIKit
#endif
import AVFoundation
import ImageIO

enum Renderer {
    /// Draws one frame's art (no background) in document coordinates, bottom layer first.
    static func drawFrame(_ doc: Doc, frame: Int, in ctx: CGContext) {
        func drawLayer(_ index: Int) {
            let layer = doc.layers[index]
            if !layer.visible { return }
            let alpha = layer.alpha
            if alpha <= 0 { return }
            if alpha < 1 {
                // Fade the layer as one piece, so overlapping art doesn't show through.
                ctx.saveGState()
                ctx.setAlpha(alpha)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            }
            drawShapes(layer.shapes(at: frame), doc: doc, in: ctx)
            if alpha < 1 {
                ctx.endTransparencyLayer()
                ctx.restoreGState()
            }
        }

        // Bottom to top. A layer that isn't clipped is a base; the clipped layers sitting
        // straight above it are drawn together, then trimmed to the base's art.
        var li = doc.layers.count - 1
        while li >= 0 {
            let base = li
            li -= 1
            var clipped: [Int] = []
            while li >= 0 && doc.layers[li].isClipped {
                clipped.append(li)
                li -= 1
            }
            drawLayer(base)
            let baseLayer = doc.layers[base]
            guard !clipped.isEmpty, baseLayer.visible, baseLayer.alpha > 0 else { continue }
            let baseArt = baseLayer.shapes(at: frame)
            if baseArt.isEmpty { continue }
            ctx.saveGState()
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            for i in clipped {
                drawLayer(i)
            }
            // Keep only what lies over the base's art.
            ctx.setBlendMode(.destinationIn)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            drawShapes(baseArt, doc: doc, in: ctx)
            ctx.endTransparencyLayer()
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
    }

    /// Draws fills and library instances, bottom first. Symbols may contain other symbols;
    /// `depth` stops runaway nesting.
    static func drawShapes(_ shapes: [Shape], doc: Doc, in ctx: CGContext, depth: Int = 0) {
        for shape in shapes {
            guard let ref = shape.ref else {
                ctx.addPath(shape.path)
                ctx.setFillColor(shape.color.cgColor)
                ctx.fillPath(using: .winding)
                continue
            }
            guard depth < 8, let item = doc.item(ref) else { continue }
            let fade = max(0, min(1, shape.color.a))
            if fade <= 0 { continue }
            ctx.saveGState()
            if fade < 1 {
                // A copy's opacity fades it as one piece.
                ctx.setAlpha(fade)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            }
            defer {
                if fade < 1 { ctx.endTransparencyLayer() }
                ctx.restoreGState()
            }
            ctx.concatenate(shape.transform)
            if item.isSymbol {
                drawShapes(item.shapes ?? [], doc: doc, in: ctx, depth: depth + 1)
            } else if let img = ImageCache.shared.image(for: item) {
                // Documents are y-down; images draw y-up.
                ctx.translateBy(x: 0, y: item.height)
                ctx.scaleBy(x: 1, y: -1)
                ctx.interpolationQuality = .high
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: item.width, height: item.height))
            }
        }
    }

    /// Renders a finished frame on its background, at `scale` pixels per stage point.
    static func image(doc: Doc, frame: Int, scale: CGFloat = 1) -> CGImage? {
        let w = max(1, Int((doc.width * scale).rounded()))
        let h = max(1, Int((doc.height * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(doc.background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // Documents are y-down; bitmap contexts are y-up.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        drawFrame(doc, frame: frame, in: ctx)
        return ctx.makeImage()
    }

    static func pngData(_ image: CGImage) -> Data? {
        #if os(macOS)
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
        #else
        return UIImage(cgImage: image).pngData()
        #endif
    }

    static func writePNGSequence(doc: Doc, to folder: URL, baseName: String) -> Bool {
        var ok = true
        for f in 0..<max(1, doc.length) {
            guard let img = image(doc: doc, frame: f), let data = pngData(img) else {
                ok = false
                continue
            }
            let name = String(format: "%@_%04d.png", baseName, f + 1)
            do {
                try data.write(to: folder.appendingPathComponent(name))
            } catch {
                ok = false
            }
        }
        return ok
    }

    static func writeGIF(doc: Doc, to url: URL) -> Bool {
        let count = max(1, doc.length)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, count, nil) else {
            return false
        }
        let gifKey = kCGImagePropertyGIFDictionary as String
        let fileProps: [String: Any] = [gifKey: [kCGImagePropertyGIFLoopCount as String: 0]]
        CGImageDestinationSetProperties(dest, fileProps as CFDictionary)
        let delay = 1.0 / Double(max(1, doc.fps))
        let frameProps: [String: Any] = [gifKey: [
            kCGImagePropertyGIFDelayTime as String: delay,
            kCGImagePropertyGIFUnclampedDelayTime as String: delay
        ]]
        for f in 0..<count {
            if let img = image(doc: doc, frame: f) {
                CGImageDestinationAddImage(dest, img, frameProps as CFDictionary)
            }
        }
        return CGImageDestinationFinalize(dest)
    }

    // MARK: Video

    /// Exports an H.264 .mp4 of the whole timeline, with the soundtrack when there is one.
    static func writeVideo(doc: Doc, audio: URL?, to url: URL) -> Bool {
        try? FileManager.default.removeItem(at: url)
        guard let audio = audio else {
            return writeSilentVideo(doc: doc, to: url, fileType: .mp4)
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("swiftcel-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard writeSilentVideo(doc: doc, to: temp, fileType: .mov) else { return false }
        return mux(video: temp, audio: audio, to: url)
    }

    private static func writeSilentVideo(doc: Doc, to url: URL, fileType: AVFileType) -> Bool {
        // Render at 2x for crisp edges unless that would be enormous; H.264 wants even sizes.
        let scale: CGFloat = doc.width * 2 <= 3840 && doc.height * 2 <= 2160 ? 2 : 1
        let w = max(2, Int((doc.width * scale).rounded()) / 2 * 2)
        let h = max(2, Int((doc.height * scale).rounded()) / 2 * 2)
        let count = max(1, doc.length)
        let fps = Int32(max(1, doc.fps))

        guard let writer = try? AVAssetWriter(outputURL: url, fileType: fileType),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return false }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let bufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                           sourcePixelBufferAttributes: bufferAttrs)
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: CMTime.zero)

        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        for f in 0..<count {
            var waited = 0
            while !input.isReadyForMoreMediaData && waited < 4000 {
                Thread.sleep(forTimeInterval: 0.005)
                waited += 1
            }
            guard let pool = adaptor.pixelBufferPool else { return false }
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
            guard let buffer = made else { return false }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h,
                                   bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                   space: space, bitmapInfo: bitmapInfo) {
                ctx.setFillColor(doc.background.cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                // Each frame goes through the same path as the other exports.
                if let img = image(doc: doc, frame: f, scale: CGFloat(w) / doc.width) {
                    ctx.interpolationQuality = .high
                    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let time = CMTime(value: CMTimeValue(f), timescale: fps)
            if !adaptor.append(buffer, withPresentationTime: time) { return false }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(count), timescale: fps))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting {
            done.signal()
        }
        done.wait()
        return writer.status == .completed
    }

    /// Joins the rendered picture and the soundtrack; the sound is cut off where the picture ends.
    private static func mux(video: URL, audio: URL, to url: URL) -> Bool {
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)
        let mix = AVMutableComposition()
        guard let sourceVideo = videoAsset.tracks(withMediaType: .video).first,
              let videoTrack = mix.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return false }
        let length = videoAsset.duration
        do {
            try videoTrack.insertTimeRange(CMTimeRange(start: CMTime.zero, duration: length), of: sourceVideo, at: CMTime.zero)
        } catch {
            return false
        }
        if let sourceAudio = audioAsset.tracks(withMediaType: .audio).first,
           let audioTrack = mix.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let audible = CMTimeMinimum(length, audioAsset.duration)
            try? audioTrack.insertTimeRange(CMTimeRange(start: CMTime.zero, duration: audible), of: sourceAudio, at: CMTime.zero)
        }
        guard let session = AVAssetExportSession(asset: mix, presetName: AVAssetExportPresetHighestQuality) else {
            return false
        }
        session.outputURL = url
        session.outputFileType = .mp4
        let done = DispatchSemaphore(value: 0)
        session.exportAsynchronously {
            done.signal()
        }
        done.wait()
        return session.status == .completed
    }

    static func svg(doc: Doc, frame: Int) -> String {
        let w = String(format: "%.0f", Double(doc.width))
        let h = String(format: "%.0f", Double(doc.height))
        var out = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(w)\" height=\"\(h)\" viewBox=\"0 0 \(w) \(h)\">\n"
        out += "  <rect width=\"\(w)\" height=\"\(h)\" fill=\"\(doc.background.hex)\"/>\n"
        func layerGroup(_ layer: Layer) -> String {
            guard layer.visible else { return "" }
            let layerOpacity = String(format: "%.3f", Double(layer.alpha))
            return "  <g opacity=\"\(layerOpacity)\">\n" + svgShapes(layer.shapes(at: frame), doc: doc, depth: 0) + "  </g>\n"
        }
        // Same order and grouping as drawFrame: clipped layers are wrapped in a clip path
        // made from their base layer's fills.
        var li = doc.layers.count - 1
        var clipCount = 0
        while li >= 0 {
            let base = doc.layers[li]
            li -= 1
            var clipped: [Layer] = []
            while li >= 0 && doc.layers[li].isClipped {
                clipped.append(doc.layers[li])
                li -= 1
            }
            out += layerGroup(base)
            guard !clipped.isEmpty, base.visible else { continue }
            let fills = base.shapes(at: frame).filter { !$0.isInstance }
            if fills.isEmpty { continue }
            clipCount += 1
            out += "  <clipPath id=\"clip\(clipCount)\">\n"
            for f in fills {
                out += "    <path d=\"\(PathText.string(from: f.path))\"/>\n"
            }
            out += "  </clipPath>\n  <g clip-path=\"url(#clip\(clipCount))\">\n"
            for layer in clipped {
                out += layerGroup(layer)
            }
            out += "  </g>\n"
        }
        out += "</svg>\n"
        return out
    }

    private static func svgShapes(_ shapes: [Shape], doc: Doc, depth: Int) -> String {
        var out = ""
        for shape in shapes {
            guard let ref = shape.ref else {
                let d = PathText.string(from: shape.path)
                let opacity = String(format: "%.3f", Double(shape.color.a))
                out += "    <path d=\"\(d)\" fill=\"\(shape.color.hex)\" fill-opacity=\"\(opacity)\" fill-rule=\"nonzero\"/>\n"
                continue
            }
            guard depth < 8, let item = doc.item(ref) else { continue }
            let t = shape.transform
            let matrix = String(format: "matrix(%.4f %.4f %.4f %.4f %.2f %.2f)",
                                Double(t.a), Double(t.b), Double(t.c), Double(t.d), Double(t.tx), Double(t.ty))
            out += "    <g transform=\"\(matrix)\">\n"
            if item.isSymbol {
                out += svgShapes(item.shapes ?? [], doc: doc, depth: depth + 1)
            } else if let data = item.image {
                let w = String(format: "%.2f", Double(item.width))
                let h = String(format: "%.2f", Double(item.height))
                let mime = data.first == 0xFF ? "image/jpeg" : "image/png"
                out += "    <image width=\"\(w)\" height=\"\(h)\" href=\"data:\(mime);base64,\(data.base64EncodedString())\"/>\n"
            }
            out += "    </g>\n"
        }
        return out
    }
}

/// Decoded bitmaps, kept so each redraw doesn't decode the file again.
final class ImageCache {
    static let shared = ImageCache()
    private var images: [String: CGImage] = [:]
    /// The iPad draws the stage on a background thread, so lookups take turns.
    private let lock = NSLock()

    func image(for item: LibraryItem) -> CGImage? {
        lock.lock()
        let cached = images[item.id]
        lock.unlock()
        if let hit = cached { return hit }
        guard let data = item.image,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        lock.lock()
        images[item.id] = img
        lock.unlock()
        return img
    }
}
