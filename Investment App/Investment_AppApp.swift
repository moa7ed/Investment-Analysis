//
//  Investment_AppApp.swift
//  Investment App
//
//  Created by Mohammed Elrashidy on 10/09/2026.
//

import SwiftUI
import SwiftData
import UserNotifications

@main
struct Investment_AppApp: App {
    @State private var store = Self.makeStore()
    /// Market analyses and their recommendations
    private let modelContainer = Self.makeModelContainer()

    init() {
        // Set at launch so tapping a notification that launched the app is handled
        UNUserNotificationCenter.current().delegate = AnalysisNotificationRouter.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store, initialImports: Self.initialImports)
        }
        .modelContainer(modelContainer)
    }

    /// The on-disk analysis history, or an empty in-memory one for UI tests.
    private static func makeModelContainer() -> ModelContainer {
        var inMemory = false
        #if DEBUG
        inMemory = UITestEnvironment.isEnabled
        #endif
        do {
            return try ModelContainer(
                for: AnalysisRecord.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: inMemory)
            )
        } catch {
            fatalError("Couldn't open the analysis history: \(error)")
        }
    }

    /// The real store, or an offline stubbed one when launched by UI tests.
    private static func makeStore() -> PortfolioStore {
        #if DEBUG
        if UITestEnvironment.isEnabled {
            return UITestEnvironment.makeStore()
        }
        #endif
        return PortfolioStore()
    }

    private static var initialImports: [StatementSource] {
        #if DEBUG
        return UITestEnvironment.sampleImports
        #else
        return []
        #endif
    }
}
