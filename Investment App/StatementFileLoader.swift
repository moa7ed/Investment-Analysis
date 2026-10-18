//
//  StatementFileLoader.swift
//  Investment App
//
//  Created by Mohammed Elrashidy on 10/10/2026.
//

import Foundation
import UIKit
import UniformTypeIdentifiers

/// A statement file converted into a Claude content block, ready to send.
struct StatementSource {
    /// File name shown in the import preview and in error messages.
    let name: String
    let contentBlock: [String: Any]
    /// The original file contents and type, kept so the statement can be viewed in the import preview.
    var originalData: Data? = nil
    var contentType: UTType? = nil

    /// Whether the original file is available to view.
    var canPreview: Bool { originalData != nil }

    /// Writes the original file to a temporary location for Quick Look, with an extension so its type is recognised.
    func writePreviewFile() throws -> URL {
        guard let originalData else { throw StatementFileError.unreadable(name: name) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StatementPreviews", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var fileName = name
        if URL(fileURLWithPath: name).pathExtension.isEmpty, let ext = contentType?.preferredFilenameExtension {
            fileName += ".\(ext)"
        }
        let url = directory.appendingPathComponent(fileName)
        try originalData.write(to: url, options: .atomic)
        return url
    }
}

enum StatementFileError: LocalizedError {
    case unsupported(name: String)
    case unreadable(name: String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let name):
            "\(name) can't be read. Export it as PDF or CSV and try again."
        case .unreadable(let name):
            "\(name) couldn't be opened."
        }
    }
}

/// Converts files from the file picker, Photos, or the share sheet into content Claude can read:
/// PDFs as documents, images as JPEG/PNG/GIF/WebP, and text-based files (CSV, TXT, …) as text.
enum StatementFileLoader {
    /// Longest image edge sent to Claude — large enough to keep statement text legible.
    private static let maxImageDimension: CGFloat = 2000
    /// Raw size cap so the base64-encoded image stays under the API's 5 MB per-image limit.
    private static let maxImageBytes = 3_700_000
    /// Image formats Claude accepts directly; anything else (e.g. HEIC) is converted to JPEG.
    private static let directImageTypes: [(type: UTType, mimeType: String)] = [
        (.jpeg, "image/jpeg"), (.png, "image/png"), (.gif, "image/gif"), (.webP, "image/webp")
    ]

    /// Loads a file URL from the file picker or the share sheet.
    static func load(fileAt url: URL) throws -> StatementSource {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let name = url.lastPathComponent
        guard let data = try? Data(contentsOf: url) else { throw StatementFileError.unreadable(name: name) }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        return try load(data: data, type: type, name: name)
    }

    /// Loads raw data of a known type (e.g. a photo from the Photos picker).
    static func load(data: Data, type: UTType?, name: String) throws -> StatementSource {
        guard let type else { throw StatementFileError.unsupported(name: name) }
        return StatementSource(
            name: name,
            contentBlock: try contentBlock(data: data, type: type, name: name),
            originalData: data,
            contentType: type
        )
    }

    private static func contentBlock(data: Data, type: UTType, name: String) throws -> [String: Any] {
        if type.conforms(to: .pdf) {
            return [
                "type": "document",
                "source": ["type": "base64", "media_type": "application/pdf", "data": data.base64EncodedString()]
            ]
        }

        if type.conforms(to: .image) {
            return try imageBlock(data: data, type: type, name: name)
        }

        // CSV, TSV, plain text, JSON, HTML, … all conform to public.text
        if type.conforms(to: .text) {
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            return [
                "type": "text",
                "text": "Contents of the statement file \"\(name)\":\n\n\(text)"
            ]
        }

        throw StatementFileError.unsupported(name: name)
    }

    /// Sends supported images as-is when small enough; otherwise downscales and re-encodes as JPEG.
    private static func imageBlock(data: Data, type: UTType, name: String) throws -> [String: Any] {
        guard let image = UIImage(data: data) else { throw StatementFileError.unreadable(name: name) }

        let longestEdge = max(image.size.width, image.size.height) * image.scale
        if let direct = directImageTypes.first(where: { type.conforms(to: $0.type) }),
           data.count <= maxImageBytes, longestEdge <= maxImageDimension {
            return imageBlock(data: data, mimeType: direct.mimeType)
        }

        guard let jpeg = downscaledJPEG(image) else { throw StatementFileError.unreadable(name: name) }
        return imageBlock(data: jpeg, mimeType: "image/jpeg")
    }

    private static func downscaledJPEG(_ image: UIImage) -> Data? {
        let pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let ratio = min(1, maxImageDimension / max(pixelSize.width, pixelSize.height))
        let targetSize = CGSize(width: (pixelSize.width * ratio).rounded(), height: (pixelSize.height * ratio).rounded())

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        // Drawing also applies the photo's orientation, so the result is upright
        let resized = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }

        // Step quality down only if needed to fit the size limit
        for quality in [0.85, 0.7, 0.5] {
            if let data = resized.jpegData(compressionQuality: quality), data.count <= maxImageBytes {
                return data
            }
        }
        return nil
    }

    private static func imageBlock(data: Data, mimeType: String) -> [String: Any] {
        [
            "type": "image",
            "source": ["type": "base64", "media_type": mimeType, "data": data.base64EncodedString()]
        ]
    }
}
