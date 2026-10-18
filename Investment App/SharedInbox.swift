//
//  SharedInbox.swift
//  Investment App
//
//  Created by Mohammed Elrashidy on 17/10/2026.
//

import Foundation

/// Folder in the App Group container where the Share extension drops statements for the app to import.
enum SharedInbox {
    /// Must match `ShareViewController.appGroupID` in the ShareToInvestment target.
    static let appGroupID = "group.Rashidy.Investment-App"
    private static let inboxFolder = "SharedInbox"
    /// The Share extension opens `investmentapp://import` after saving (registered in Investment-App-Info.plist).
    static let urlScheme = "investmentapp"

    private static var inboxURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(inboxFolder, isDirectory: true)
    }

    /// Files waiting to be imported, oldest first. Each is in its own folder so its name stays readable.
    static func pendingFiles() -> [URL] {
        guard let inbox = inboxURL,
              let enumerator = FileManager.default.enumerator(
                at: inbox,
                includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey]
              )
        else { return [] }

        let files = enumerator.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        return files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a < b
        }
    }

    /// Deletes a file and its per-item folder once it has been read.
    static func remove(_ file: URL) {
        let folder = file.deletingLastPathComponent()
        if folder.lastPathComponent != inboxFolder {
            try? FileManager.default.removeItem(at: folder)
        } else {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
