//
//  TargetGap.swift
//  Investment App
//
//  Created by Mohammed Elrashidy on 18/10/2026.
//

import SwiftUI
import UIKit

/// How far a sector or investment is from its target. Being over or under isn't good or bad, so it's shown
/// with an arrow and words, coloured orange (over) or blue (under) only when outside the tolerance.
struct TargetGap {
    enum Direction {
        case onTarget, over, under
    }

    /// Within this many percentage points of target counts as on target
    static let tolerance = 2.0

    /// Orange and blue read as opposites without implying good/bad, and stay distinct with colour blindness.
    /// Shades checked for colour-blind separation and contrast against light and dark backgrounds.
    static let overColor = adaptive(light: 0xD46A00, dark: 0xD27500)
    static let underColor = adaptive(light: 0x007AFF, dark: 0x0A84FF)

    let currentPercentage: Double
    let targetPercentage: Double
    /// Current value minus target value, in GBP
    let amountGBP: Double

    var direction: Direction {
        if abs(currentPercentage - targetPercentage) <= Self.tolerance { return .onTarget }
        return currentPercentage > targetPercentage ? .over : .under
    }

    var isOnTarget: Bool {
        direction == .onTarget
    }

    /// Nothing held and nothing targeted — no gap to talk about.
    var isEmpty: Bool {
        currentPercentage == 0 && targetPercentage == 0
    }

    /// Orange when over, blue when under, neutral grey when on target.
    var color: Color {
        switch direction {
        case .onTarget: .secondary
        case .over: Self.overColor
        case .under: Self.underColor
        }
    }

    /// e.g. "▲ £1,240 over", "▼ £860 under", "✓ on target" — only the arrow is coloured; the words stay in text ink.
    var label: Text {
        let amount = abs(amountGBP).formatted(.currency(code: "GBP").precision(.fractionLength(0)))
        switch direction {
        case .onTarget:
            return Text("\(Image(systemName: "checkmark")) on target")
        case .over:
            return Text("\(Text(Image(systemName: "arrowtriangle.up.fill")).foregroundStyle(color)) \(amount) over")
        case .under:
            return Text("\(Text(Image(systemName: "arrowtriangle.down.fill")).foregroundStyle(color)) \(amount) under")
        }
    }

    /// Spoken by VoiceOver instead of the arrow symbols.
    var accessibilityDescription: String {
        let amount = abs(amountGBP).formatted(.currency(code: "GBP").precision(.fractionLength(0)))
        switch direction {
        case .onTarget: return "On target"
        case .over: return "\(amount) over target"
        case .under: return "\(amount) under target"
        }
    }

    /// Off-target gaps in primary ink so they stand out; on-target in secondary.
    var labelStyle: Color {
        isOnTarget ? .secondary : .primary
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}
