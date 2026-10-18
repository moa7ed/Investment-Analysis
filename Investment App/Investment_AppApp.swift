//
//  Investment_AppApp.swift
//  Investment App
//
//  Created by Mohammed Elrashidy on 10/09/2026.
//

import SwiftUI

@main
struct Investment_AppApp: App {
    @State private var store = Self.makeStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store, initialImports: Self.initialImports)
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
