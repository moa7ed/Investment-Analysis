//
//  MarketAnalysisRunner.swift
//  Investment App
//
//  Created by Mohammed Elrashidy on 18/10/2026.
//

import BackgroundTasks
import Foundation
import SwiftData
import UserNotifications

/// Runs a market analysis so it keeps going if the user leaves the app, saves the result,
/// and sends a notification when it's done.
@MainActor
enum MarketAnalysisRunner {
    /// Research, analysis, then saving.
    private static let progressSteps: Int64 = 3

    /// Starts an analysis. `completion` runs on the main actor once the result is saved (or the run failed).
    static func start(
        store: PortfolioStore,
        context: ModelContext,
        instructions: String,
        termsExplainedToday: [String],
        feedback: [AnalysisFeedback],
        completion: @escaping (Result<Void, ClaudeFailure>) -> Void
    ) {
        AnalysisNotifications.requestAuthorization()

        let progress = Progress(totalUnitCount: progressSteps)
        let work = Task {
            await store.analyseMarket(
                additionalInstructions: instructions,
                termsExplainedToday: termsExplainedToday,
                feedback: feedback,
                progress: progress
            )
        }
        continueInBackground(work, progress: progress)

        Task {
            switch await work.value {
            case .success(let analysis):
                context.insert(AnalysisRecord(analysis))
                do {
                    try context.save()
                } catch {
                    print("[Analysis] Couldn't save the analysis: \(error)")
                }
                progress.completedUnitCount = progressSteps
                AnalysisNotifications.postFinished(analysis)
                completion(.success(()))
            case .failure(let failure):
                AnalysisNotifications.postFailed(failure)
                completion(.failure(failure))
            }
        }
    }

    /// Asks iOS to keep the app running if it's backgrounded mid-analysis. The system shows the progress
    /// and lets the user cancel, which cancels the analysis. If iOS declines, the analysis still runs while the app is open.
    private static func continueInBackground(_ work: Task<Result<MarketAnalysis, ClaudeFailure>, Never>, progress: Progress) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        // Unique per run: registering the same identifier twice terminates the app
        let identifier = "\(bundleID).marketAnalysis.\(UUID().uuidString)"

        // The main queue, since the handler touches main-actor state
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            task.progress.totalUnitCount = progressSteps
            task.progress.addChild(progress, withPendingUnitCount: progressSteps)
            task.expirationHandler = { work.cancel() }
            Task {
                let result = await work.value
                if case .success = result {
                    task.setTaskCompleted(success: true)
                } else {
                    task.setTaskCompleted(success: false)
                }
            }
        }
        guard registered else {
            print("[Analysis] Couldn't register the background task")
            return
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
        } catch {
            print("[Analysis] Background continuation unavailable: \(error)")
        }
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
