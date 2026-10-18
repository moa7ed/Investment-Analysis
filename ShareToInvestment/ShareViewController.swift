//
//  ShareViewController.swift
//  ShareToInvestment
//
//  Created by Mohammed Elrashidy on 17/10/2026.
//

import UIKit
import SwiftUI
import UniformTypeIdentifiers

/// Receives screenshots, photos, PDFs and CSV/text files from the share sheet, drops them into the
/// App Group inbox, then opens the app, which imports everything in the inbox.
class ShareViewController: UIViewController {

    /// Must match `SharedInbox.appGroupID` / `urlScheme` in the app target.
    private static let appGroupID = "group.Rashidy.Investment-App"
    private static let inboxFolder = "SharedInbox"
    private static let openAppURL = URL(string: "investmentapp://import")!

    /// Types the app can import, in preference order (a screenshot offers both PNG and JPEG, for example).
    private static let acceptedTypes: [UTType] = [.pdf, .png, .jpeg, .heic, .image, .commaSeparatedText, .tabSeparatedText, .plainText]

    private let status = ShareStatus()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareStatusView(status: status) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        })
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        Task { await saveAttachments() }
    }

    private func saveAttachments() async {
        guard let inbox = Self.inboxURL() else {
            status.state = .failed("Couldn't open the shared folder. Check the App Group is enabled for both targets.")
            return
        }
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }

        var saved = 0
        for (index, provider) in providers.enumerated() {
            if await save(provider, index: index, to: inbox) {
                saved += 1
            }
        }
        guard saved > 0 else {
            status.state = .failed("Nothing here can be imported. Share a screenshot, photo, PDF or CSV.")
            return
        }
        status.state = .saved(saved)

        // Jump straight to the app; if that's blocked, the "Open Investment App" message stays up instead
        if openContainingApp() {
            extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }

    /// Opens the app via its URL scheme.
    ///
    /// Share extensions have no supported API for this (`NSExtensionContext.open` only works for Today and
    /// iMessage extensions), so this finds the host `UIApplication` in the responder chain and calls
    /// `open(_:options:completionHandler:)` through the Objective-C runtime — that method is marked
    /// unavailable to extensions at compile time. Unofficial: fine for a personally installed app, but App
    /// Review may reject it and a future iOS could stop it working. Returns false if it couldn't be called.
    private func openContainingApp() -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication, application.responds(to: selector) {
                typealias OpenURL = @convention(c) (
                    NSObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?
                ) -> Void
                let open = unsafeBitCast(application.method(for: selector), to: OpenURL.self)
                open(application, selector, Self.openAppURL as NSURL, NSDictionary(), nil)
                return true
            }
            responder = current.next
        }
        return false
    }

    /// Copies one attachment into the inbox with an extension that matches its type.
    private func save(_ provider: NSItemProvider, index: Int, to inbox: URL) async -> Bool {
        guard let type = Self.acceptedTypes.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) else {
            return false
        }
        let ext = type.preferredFilenameExtension ?? "png"
        // suggestedName may already carry an extension (e.g. "IMG_8886.PNG")
        let base = provider.suggestedName.map { ($0 as NSString).deletingPathExtension } ?? "Shared \(index + 1)"
        // Each item gets its own folder so the file keeps its readable name (shown in the import preview)
        let folder = inbox.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else {
            return false
        }
        let destination = folder.appendingPathComponent("\(base).\(ext)")

        // Most sources hand over data; some (e.g. the screenshot editor) only offer a UIImage object
        if let data = await Self.loadData(from: provider, type: type) {
            return (try? data.write(to: destination)) != nil
        }
        if type.conforms(to: .image),
           let image = try? await provider.loadItem(forTypeIdentifier: type.identifier) as? UIImage,
           let png = image.pngData() {
            let pngURL = destination.deletingPathExtension().appendingPathExtension("png")
            return (try? png.write(to: pngURL)) != nil
        }
        return false
    }

    private static func loadData(from provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    private static func inboxURL() -> URL? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return nil
        }
        let inbox = container.appendingPathComponent(inboxFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        return inbox
    }
}

// MARK: - Status UI

@Observable
private final class ShareStatus {
    enum State {
        case saving
        case saved(Int)
        case failed(String)
    }
    var state: State = .saving
}

private struct ShareStatusView: View {
    let status: ShareStatus
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                switch status.state {
                case .saving:
                    ProgressView()
                    Text("Sending to Investment App…")
                case .saved(let count):
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                    Text(count == 1 ? "Statement sent" : "\(count) statements sent")
                        .font(.headline)
                    Text("Open Investment App to review and import.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    Text(message)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Investment App")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
    }
}
