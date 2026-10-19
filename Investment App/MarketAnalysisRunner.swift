//
//  MarketAnalysisRunner.swift
//  Investment App
//
//  Created by Mohammed Elrashidy on 18/10/2026.
//

import BackgroundTasks
import Foundation
import OSLog
import SwiftData
import UserNotifications

/// Runs a market analysis so it keeps going if the user leaves the app, saves the result,
/// and sends a notification when it's done.
@MainActor
enum MarketAnalysisRunner {
    /// Research, analysis, then saving.
    private static let progressSteps: Int64 = 3

    /// Set from the background task's expiration handler, which iOS may call on any thread.
    private final class ExpirationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var expired = false

        var isSet: Bool { lock.withLock { expired } }
        func set() { lock.withLock { expired = true } }
    }

    /// Starts an analysis. `completion` runs on the main actor once the result is saved (or the run failed).
    static func start(
        store: PortfolioStore,
        context: ModelContext,
        instructions: String,
        termsExplainedToday: [String],
        feedback: [AnalysisFeedback],
        earlierResearch: EarlierResearch?,
        completion: @escaping (Result<Void, ClaudeFailure>) -> Void
    ) {
        AnalysisNotifications.requestAuthorization()

        let progress = Progress(totalUnitCount: progressSteps)
        let expiration = ExpirationFlag()
        let work = Task {
            await store.analyseMarket(
                additionalInstructions: instructions,
                termsExplainedToday: termsExplainedToday,
                feedback: feedback,
                earlierResearch: earlierResearch,
                progress: progress
            )
        }
        store.marketAnalysisBackground = continueInBackground(work, progress: progress, expiration: expiration, store: store)

        Task {
            let result = await work.value.mapError { failure in
                explainBackgroundStop(failure, expired: expiration.isSet, background: store.marketAnalysisBackground)
            }
            store.marketAnalysisBackground = nil
            switch result {
            case .success(let analysis):
                context.insert(AnalysisRecord(analysis))
                do {
                    try context.save()
                } catch {
                    print("[Analysis] Couldn't save the analysis: \(error)")
                }
                progress.completedUnitCount = progressSteps
                ClaudeLog.logger.info("Market analysis finished with \(analysis.recommendations.count, privacy: .public) recommendations")
                AnalysisNotifications.postFinished(analysis)
                completion(.success(()))
            case .failure(let failure):
                ClaudeLog.logger.error("Market analysis failed: \(failure.message, privacy: .public)")
                AnalysisNotifications.postFailed(failure)
                completion(.failure(failure))
            }
        }
    }

    /// Asks iOS to keep the app running if it's backgrounded mid-analysis. The system shows the progress
    /// and lets the user cancel, which cancels the analysis. If iOS declines, the analysis still runs while the app is open.
    /// - Returns: Whether iOS accepted the request, for the analysis screen to tell the user.
    private static func continueInBackground(
        _ work: Task<Result<MarketAnalysis, ClaudeFailure>, Never>,
        progress: Progress,
        expiration: ExpirationFlag,
        store: PortfolioStore
    ) -> MarketAnalysisBackground {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            return .unavailable("The app has no bundle identifier.")
        }
        // Unique per run: registering the same identifier twice terminates the app
        let identifier = "\(bundleID).marketAnalysis.\(UUID().uuidString)"

        // The main queue, since the handler touches main-actor state
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            guard let task = task as? BGContinuedProcessingTask else {
                ClaudeLog.logger.error("Background task started with an unexpected type: \(String(describing: type(of: task)), privacy: .public)")
                task.setTaskCompleted(success: false)
                return
            }
            ClaudeLog.logger.info("Background task started")
            // Report progress on the task's own counter, as Apple's example does. (A child progress only moves
            // the parent's counter when the child finishes, so iOS would see no progress until the very end.)
            task.progress.totalUnitCount = taskProgressUnits
            var lastSubtitle = ""
            let mirror = {
                task.progress.completedUnitCount = Int64(progress.fractionCompleted * Double(taskProgressUnits))
                // The system's progress UI shows the current step, updated only when it changes
                let subtitle = backgroundSubtitle(store)
                if subtitle != lastSubtitle {
                    lastSubtitle = subtitle
                    task.updateTitle(task.title, subtitle: subtitle)
                }
            }
            mirror()
            let observation = progress.observe(\.fractionCompleted) { _, _ in
                Task { @MainActor in mirror() }
            }
            task.expirationHandler = {
                // iOS ends the task (low resources, the task looked stuck, or the user cancelled it from the system UI)
                ClaudeLog.logger.error("Background task expired at \(Int(progress.fractionCompleted * 100), privacy: .public)% — cancelling the analysis")
                expiration.set()
                work.cancel()
            }
            Task {
                let result = await work.value
                observation.invalidate()
                if case .success = result {
                    task.setTaskCompleted(success: true)
                } else {
                    task.setTaskCompleted(success: false)
                }
                ClaudeLog.logger.info("Background task completed")
            }
        }
        guard registered else {
            ClaudeLog.logger.error("Couldn't register the background task \(identifier, privacy: .public)")
            return .unavailable("iOS didn't accept the background task.")
        }

        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: "Market Analysis",
            subtitle: MarketAnalysisPhase.researching.message
        )
        // Start now or not at all — a queued continuation would begin after the analysis already started
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            ClaudeLog.logger.info("Background task submitted")
            return .allowed
        } catch {
            let reason = describe(error)
            ClaudeLog.logger.error("Background task refused: \(reason, privacy: .public) (\(String(describing: error), privacy: .public))")
            return .unavailable(reason)
        }
    }

    /// Units of the system task's progress; fine enough that every heartbeat advance changes the count.
    private static let taskProgressUnits: Int64 = 1_000_000

    /// e.g. "Researching the market… · 12 searches · 31 sites" or "Writing recommendations (14 so far)".
    private static func backgroundSubtitle(_ store: PortfolioStore) -> String {
        guard let phase = store.marketAnalysisPhase else { return "Saving the analysis" }
        switch phase {
        case .researching:
            let counts = store.marketAnalysisActivity.first?.detail?.components(separatedBy: "\n").first
            return [phase.message, counts].compactMap { $0 }.joined(separator: " · ")
        case .analysing:
            return store.marketAnalysisActivity.last { $0.kind == .writing }?.text ?? phase.message
        }
    }

    /// Why iOS refused the background task, in plain words.
    private static func describe(_ error: Error) -> String {
        guard let code = (error as? BGTaskScheduler.Error)?.code else { return error.localizedDescription }
        return switch code {
        case .unavailable: "Background running isn't available (for example Low Power Mode, or Background App Refresh is off)."
        case .immediateRunIneligible: "iOS can't start it right now."
        case .tooManyPendingTaskRequests: "Too many background tasks are already waiting."
        case .notPermitted: "The app isn't permitted to run this in the background."
        default: error.localizedDescription
        }
    }

    /// Replaces "cancelled" and dropped-connection failures with the real reason when iOS stopped the analysis.
    private static func explainBackgroundStop(
        _ failure: ClaudeFailure,
        expired: Bool,
        background: MarketAnalysisBackground?
    ) -> ClaudeFailure {
        guard failure.isConnectionFailure else { return failure }
        if expired {
            return .backgroundStopped(
                "iOS stopped the analysis while the app was in the background. Keep the app open until it finishes, then try again."
            )
        }
        if case .unavailable(let reason) = background {
            return .backgroundStopped(
                "The analysis stopped when the app left the screen, because iOS didn't allow it to run in the background: \(reason) Keep the app open until it finishes."
            )
        }
        return failure
    }
}

// MARK: - Notifications

/// Local notifications for finished analyses.
@MainActor
enum AnalysisNotifications {
    private static let identifier = "marketAnalysis"

    /// Shows the permission prompt the first time; does nothing once the user has answered.
    static func requestAuthorization() {
        Task {
            do {
                _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            } catch {
                print("[Analysis] Notification permission error: \(error)")
            }
        }
    }

    static func postFinished(_ analysis: MarketAnalysis) {
        let counts = RecommendationAction.allCases.compactMap { action -> String? in
            let count = analysis.recommendations.filter { $0.action == action }.count
            return count > 0 ? "\(count) \(action.rawValue)" : nil
        }
        post(
            title: "Market analysis ready",
            body: counts.isEmpty ? "Tap to read the summary." : "\(counts.joined(separator: " · ")). Tap to see the recommendations."
        )
    }

    static func postFailed(_ failure: ClaudeFailure) {
        post(title: "Market analysis failed", body: failure.message)
    }

    private static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // Same identifier, so a new result replaces an older unread one
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[Analysis] Couldn't post the notification: \(error)")
            }
        }
    }
}

/// Shows analysis notifications while the app is open (unless the analysis screen is already visible)
/// and opens the analysis screen when one is tapped.
@MainActor
@Observable
final class AnalysisNotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AnalysisNotificationRouter()

    /// Set when the user taps a notification; the home screen opens the analysis and clears it.
    var opensMarketAnalysis = false
    /// True while the analysis screen is on screen, where a banner would be redundant.
    var isShowingMarketAnalysis = false

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        await isShowingMarketAnalysis ? [] : [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run { opensMarketAnalysis = true }
    }
}
