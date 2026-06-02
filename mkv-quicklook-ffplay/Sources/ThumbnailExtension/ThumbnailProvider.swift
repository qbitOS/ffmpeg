import QuickLookThumbnailing
import AppKit
import Foundation
import UniformTypeIdentifiers

// NOTE: This file must be added to the MKVQuickLookQLThumbnail target only.

class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {

        let maxSize = request.maximumSize
        let scale = maxSize.width > 256 ? 2.0 : 1.0   // retina-ish
        let targetSize = CGSize(width: min(maxSize.width, 512), height: min(maxSize.height, 512))

        // Try to get a real frame using FFMPEG helper if the binary is reachable from here.
        // This often works when we bundled a copy; otherwise we fall back to a drawn representation.
        if let jpegData = FFMPEG.extractFrame(from: request.fileURL, at: 12.0, maxWidth: Int(targetSize.width)) {
            // We have image data → hand it to QL as a file-backed or data reply is convenient.
            // Easiest: write a tiny temp jpeg and use QLThumbnailReply(file: ...)
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mkvthumb-\(UUID().uuidString).jpg")
            do {
                try jpegData.write(to: tmp)
                let reply = QLThumbnailReply(fileURL: tmp, contentType: UTType.jpeg)
                // QL will delete? No, but it's ok, temp will be cleaned eventually.
                handler(reply, nil)
                return
            } catch {
                // fall through to drawn
            }
        }

        // Fallback: draw a nice placeholder representing an MKV video file.
        // We also try the pure-Swift parser for duration/badge info.
        var md: MKVMetadata?
        do { md = try parseMKVMetadata(at: request.fileURL) } catch {}

        handler(QLThumbnailReply(contextSize: targetSize, currentContextDrawing: { (cgContext) -> Bool in
            let ctx = cgContext
            let rect = CGRect(origin: .zero, size: targetSize)

            // Background dark cinematic
            ctx.setFillColor(CGColor(gray: 0.08, alpha: 1.0))
            ctx.fill(rect)

            // Subtle film-strip edges
            ctx.setFillColor(CGColor(gray: 0.15, alpha: 1.0))
            let holeW: CGFloat = 14
            for x in stride(from: 6.0, to: rect.maxX, by: 28) {
                ctx.fill(CGRect(x: x, y: 6, width: holeW, height: 7))
                ctx.fill(CGRect(x: x, y: rect.maxY - 13, width: holeW, height: 7))
            }

            // Central video area
            let inner = rect.insetBy(dx: 18, dy: 22)
            ctx.setFillColor(CGColor(gray: 0.03, alpha: 1))
            ctx.fill(inner)

            // Play triangle
            ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.95, alpha: 0.9))
            let cx = inner.midX
            let cy = inner.midY
            let triSize: CGFloat = min(inner.width, inner.height) * 0.28
            let path = CGMutablePath()
            path.move(to: CGPoint(x: cx - triSize * 0.4, y: cy - triSize * 0.55))
            path.addLine(to: CGPoint(x: cx - triSize * 0.4, y: cy + triSize * 0.55))
            path.addLine(to: CGPoint(x: cx + triSize * 0.65, y: cy))
            path.closeSubpath()
            ctx.addPath(path)
            ctx.fillPath()

            // MKV badge
            ctx.setFillColor(CGColor(gray: 1.0, alpha: 0.95))
            let badge = "MKV"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.black
            ]
            let badgeSize = (badge as NSString).size(withAttributes: attrs)
            let badgeRect = CGRect(x: inner.minX + 6, y: inner.minY + 6, width: badgeSize.width + 8, height: badgeSize.height + 4)
            ctx.setFillColor(CGColor(gray: 0.95, alpha: 0.9))
            ctx.fill(badgeRect)
            (badge as NSString).draw(at: CGPoint(x: badgeRect.minX + 4, y: badgeRect.minY + 2), withAttributes: attrs)

            // Duration / info at bottom
            if let md = md, let dur = md.duration {
                let info = "\(md.formattedDuration)  ·  \(md.tracks.count) tracks"
                let iattrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 9),
                    .foregroundColor: NSColor(white: 0.9, alpha: 0.95)
                ]
                (info as NSString).draw(at: CGPoint(x: inner.minX + 6, y: inner.maxY - 16), withAttributes: iattrs)
            } else {
                let info = "Matroska Video"
                let iattrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 9),
                    .foregroundColor: NSColor(white: 0.85, alpha: 0.9)
                ]
                (info as NSString).draw(at: CGPoint(x: inner.minX + 6, y: inner.maxY - 16), withAttributes: iattrs)
            }

            // Filename hint (very bottom of whole thumb)
            ctx.setFillColor(CGColor(gray: 0.7, alpha: 0.8))
            let nameAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8),
                .foregroundColor: NSColor(white: 0.75, alpha: 1)
            ]
            let short = request.fileURL.deletingPathExtension().lastPathComponent
            (short as NSString).draw(at: CGPoint(x: 6, y: 4), withAttributes: nameAttrs)

            return true
        }), nil)
    }
}
