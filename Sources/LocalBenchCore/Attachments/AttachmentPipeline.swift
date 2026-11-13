import Foundation
import CryptoKit
import PDFKit
import Vision
import CoreGraphics
import ImageIO

/// Produces shared extracted text, page citations, hashes, and supported image
/// inputs from local files. Attachments never leave the machine (spec §7).
public struct AttachmentPipeline: Sendable {
    /// Hard limits, enforced visibly (spec §7).
    public let maxTextFileBytes: Int
    public let maxPDFPages: Int
    public let maxImageDimension: CGFloat

    public init(maxTextFileBytes: Int = 2_000_000, maxPDFPages: Int = 120, maxImageDimension: CGFloat = 1568) {
        self.maxTextFileBytes = maxTextFileBytes
        self.maxPDFPages = maxPDFPages
        self.maxImageDimension = maxImageDimension
    }

    public enum AttachmentKind: String, Codable, Sendable {
        case text
        case markdown
        case pdf
        case image
        case unsupported
    }

    public enum PipelineError: Error, Sendable {
        case unreadable(String)
        case tooLarge(Int)
        case unsupportedFormat(String)
        case imageDecodeFailed
    }

    public struct PreparedText: Sendable {
        public var kind: AttachmentKind
        public var filename: String
        public var sha256: String
        public var byteSize: Int
        /// Per-page passages for PDFs; single passage for text files.
        public var passages: [ExtractedPassage]
        public var pageCount: Int?
        public var usedOCR: Bool
    }

    // MARK: Public entry points

    public func prepare(fileURL: URL, ocrAllowed: Bool) throws -> PreparedText {
        let filename = fileURL.lastPathComponent
        let hash = try Sha256.hex(fileURL: fileURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let byteSize = (attributes[.size] as? Int) ?? 0

        switch Self.kind(forExtension: fileURL.pathExtension.lowercased(), byteSize: byteSize) {
        case .text, .markdown:
            let text = try extractText(fileURL: fileURL)
            let chunker = TextChunker()
            let chunks = chunker.chunk(text)
            let passages = chunks.map { chunk in
                ExtractedPassage(documentName: filename, pageNumber: nil, charOffset: chunk.charOffset, charLength: chunk.charLength, text: chunk.text, sha256: hash)
            }
            return PreparedText(kind: kind(forExtension: fileURL.pathExtension.lowercased()), filename: filename, sha256: hash, byteSize: byteSize, passages: passages, pageCount: nil, usedOCR: false)
        case .pdf:
            return try preparePDF(fileURL: fileURL, filename: filename, hash: hash, byteSize: byteSize, ocrAllowed: ocrAllowed)
        case .image:
            return try prepareImage(fileURL: fileURL, filename: filename, hash: hash, byteSize: byteSize, ocrAllowed: ocrAllowed)
        case .unsupported:
            throw PipelineError.unsupportedFormat(fileURL.pathExtension)
        }
    }

    public static func kind(forExtension ext: String, byteSize: Int = 0) -> AttachmentKind {
        switch ext {
        case "txt", "text": return .text
        case "md", "markdown": return .markdown
        case "pdf": return .pdf
        case "png", "jpg", "jpeg", "heic", "webp", "gif", "tiff": return .image
        default: return .unsupported
        }
    }

    func kind(forExtension ext: String) -> AttachmentKind {
        Self.kind(forExtension: ext)
    }

    // MARK: Text files

    func extractText(fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard data.count <= maxTextFileBytes else {
            throw PipelineError.tooLarge(data.count)
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw PipelineError.unreadable(fileURL.lastPathComponent)
        }
        return text
    }

    // MARK: PDF

    public func preparePDF(fileURL: URL, filename: String, hash: String, byteSize: Int, ocrAllowed: Bool) throws -> PreparedText {
        guard let document = PDFDocument(url: fileURL) else {
            throw PipelineError.unreadable(filename)
        }
        let pageCount = min(document.pageCount, maxPDFPages)
        var passages: [ExtractedPassage] = []
        var usedOCR = false
        let chunker = TextChunker()

        for pageIndex in 0..<pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let pageText = page.string ?? ""
            if pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Scanned page: OCR fallback (only with explicit user approval).
                guard ocrAllowed else { continue }
                let pageImage = page.thumbnail(of: CGSize(width: 2000, height: 2828), for: .mediaBox)
                guard let pageCGImage = pageImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                let ocrText = Self.performOCR(image: pageCGImage)
                if !ocrText.isEmpty {
                    usedOCR = true
                    let chunks = chunker.chunk(ocrText)
                    for chunk in chunks {
                        passages.append(ExtractedPassage(
                            documentName: filename,
                            pageNumber: pageIndex + 1,
                            charOffset: chunk.charOffset,
                            charLength: chunk.charLength,
                            text: chunk.text,
                            sha256: hash))
                    }
                }
                continue
            }
            let baseOffset = pageText.startIndex.utf16Offset(in: pageText)
            let chunks = chunker.chunk(pageText)
            for chunk in chunks {
                passages.append(ExtractedPassage(
                    documentName: filename,
                    pageNumber: pageIndex + 1,
                    charOffset: baseOffset + chunk.charOffset,
                    charLength: chunk.charLength,
                    text: chunk.text,
                    sha256: hash))
            }
        }
        return PreparedText(kind: .pdf, filename: filename, sha256: hash, byteSize: byteSize, passages: passages, pageCount: document.pageCount, usedOCR: usedOCR)
    }

    // MARK: Images

    public func prepareImage(fileURL: URL, filename: String, hash: String, byteSize: Int, ocrAllowed: Bool) throws -> PreparedText {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PipelineError.imageDecodeFailed
        }
        var resized = image
        let maxDimension = max(image.width, image.height)
        if maxDimension > Int(maxImageDimension) {
            let scale = maxImageDimension / CGFloat(maxDimension)
            resized = Self.resize(image: image, width: Int(CGFloat(image.width) * scale), height: Int(CGFloat(image.height) * scale)) ?? image
        }

        var ocrText: String?
        if ocrAllowed {
            let recognized = Self.performOCR(image: resized)
            if !recognized.isEmpty { ocrText = recognized }
        }

        let passage: ExtractedPassage? = ocrText.map { text in
            ExtractedPassage(documentName: filename, pageNumber: nil, charOffset: 0, charLength: text.count, text: text, sha256: hash)
        }

        return PreparedText(
            kind: .image,
            filename: filename,
            sha256: hash,
            byteSize: byteSize,
            passages: passage.map { [$0] } ?? [],
            pageCount: nil,
            usedOCR: ocrText != nil
        )
    }

    public struct PreparedImageResult: Sendable {
        public var prepared: PreparedImage
        public var ocrPassage: ExtractedPassage?
    }

    /// Prepare an image for multimodal input with visible disclosure of resizing.
    public func prepareImageForModel(fileURL: URL, ocrAllowed: Bool) throws -> PreparedImageResult {
        let prepared = try prepare(fileURL: fileURL, ocrAllowed: ocrAllowed)
        guard prepared.kind == .image else {
            throw PipelineError.unsupportedFormat(fileURL.pathExtension)
        }
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PipelineError.imageDecodeFailed
        }
        var resized = image
        var resizedWidth: Int?
        var resizedHeight: Int?
        let maxDimension = max(image.width, image.height)
        if maxDimension > Int(maxImageDimension) {
            let scale = maxImageDimension / CGFloat(maxDimension)
            resized = Self.resize(image: image, width: Int(CGFloat(image.width) * scale), height: Int(CGFloat(image.height) * scale)) ?? image
            resizedWidth = resized.width
            resizedHeight = resized.height
        }
        guard let jpegData = Self.jpegData(from: resized) else {
            throw PipelineError.imageDecodeFailed
        }
        let preparedImage = PreparedImage(
            filename: prepared.filename,
            sha256: prepared.sha256,
            jpegBytes: [UInt8](jpegData),
            originalPixelWidth: image.width,
            originalPixelHeight: image.height,
            resizedPixelWidth: resizedWidth,
            resizedPixelHeight: resizedHeight,
            ocrText: prepared.usedOCR ? prepared.passages.first?.text : nil
        )
        return PreparedImageResult(prepared: preparedImage, ocrPassage: prepared.passages.first)
    }

    // MARK: Helpers

    static func resize(image: CGImage, width: Int, height: Int) -> CGImage? {
        let context = CGContext(
            data: nil,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        guard let context else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func jpegData(from image: CGImage) -> Data? {
        let mutable = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutable, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutable as Data
    }

    static func performOCR(image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
            return request.results?
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n") ?? ""
        } catch {
            return ""
        }
    }
}
