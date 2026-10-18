//
//  AssetIcons.swift
//  Investment App
//
//  Created by Mohammed Elrashidy on 17/10/2026.
//

import SwiftUI

/// SF Symbols and colors for sectors and investment categories on the main list.
enum AssetIcons {
    /// Sector names are free-form (Claude picks them, users can edit them), so match on keywords.
    /// Order matters: the first matching rule wins (e.g. "Crypto" before "Tech").
    private static let sectorRules: [(keywords: [String], symbol: String, color: Color)] = [
        (["cash", "money market", "savings"], "sterlingsign.circle.fill", .green),
        (["crypto", "bitcoin", "blockchain", "digital asset"], "bitcoinsign.circle.fill", .orange),
        (["gold", "silver", "metal", "commodit", "mining"], "cube.fill", .yellow),
        (["energy", "oil", "gas", "utilit", "renewable", "solar"], "bolt.fill", .yellow),
        (["real estate", "property", "reit", "housing"], "building.2.fill", .brown),
        (["semiconductor", "chip"], "cpu.fill", .indigo),
        // Before Tech, so "Fintech" and "Biotech" land here
        (["financ", "bank", "insur", "payment", "fintech"], "banknote.fill", .teal),
        (["health", "pharma", "biotech", "medical"], "cross.case.fill", .red),
        (["tech", "software", "internet", "cloud", "ai", "digital"], "desktopcomputer", .blue),
        (["auto", "car", "vehicle", "ev"], "car.fill", .gray),
        (["consumer", "retail", "e-commerce", "ecommerce", "food", "beverage"], "cart.fill", .pink),
        (["industrial", "aerospace", "defen", "manufactur"], "gearshape.2.fill", .gray),
        (["telecom", "communication", "media", "entertainment"], "antenna.radiowaves.left.and.right", .purple),
        (["index", "fund", "etf", "global", "world", "diversified"], "globe", .cyan),
        (["bond", "fixed income", "gilt", "treasur"], "doc.text.fill", .mint),
    ]

    static func sector(_ name: String) -> (symbol: String, color: Color) {
        let lower = name.lowercased()
        // Whole-word match for short keywords ("ai", "ev", "car") so "Retail" doesn't match "ai"
        let words = Set(lower.split(whereSeparator: { !$0.isLetter }).map(String.init))
        for rule in sectorRules {
            let matches = rule.keywords.contains { keyword in
                keyword.count <= 3 ? words.contains(keyword) : lower.contains(keyword)
            }
            if matches {
                return (rule.symbol, rule.color)
            }
        }
        return ("chart.pie.fill", .secondary)
    }

    /// Icon for an investment's category ("Stock", "ETF", "Crypto", "Commodity", "Cash", "Real Estate").
    static func category(_ category: String) -> (symbol: String, color: Color) {
        switch category.lowercased() {
        case "cash": ("sterlingsign.circle.fill", .green)
        case "crypto": ("bitcoinsign.circle.fill", .orange)
        case "etf": ("square.stack.3d.up.fill", .cyan)
        case "commodity": ("cube.fill", .yellow)
        case "real estate": ("building.2.fill", .brown)
        default: ("chart.line.uptrend.xyaxis", .blue) // Stock and anything unrecognised
        }
    }
}

/// A symbol on a tinted rounded square, used beside sector and investment rows.
struct AssetIconView: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: size * 0.28))
            .accessibilityHidden(true)
    }
}

#Preview("Icons") {
    let sectors = ["Tech", "Semiconductors", "Crypto", "Commodities", "Index Funds", "Finance", "Fintech",
                   "Healthcare", "Biotech", "Energy", "Real Estate", "Auto", "Retail", "Cash", "Other"]
    let categories = ["Stock", "ETF", "Crypto", "Commodity", "Cash", "Real Estate"]
    List {
        Section("Sectors") {
            ForEach(sectors, id: \.self) { sector in
                let icon = AssetIcons.sector(sector)
                Label { Text(sector) } icon: { AssetIconView(symbol: icon.symbol, color: icon.color) }
            }
        }
        Section("Categories") {
            ForEach(categories, id: \.self) { category in
                let icon = AssetIcons.category(category)
                Label { Text(category) } icon: { AssetIconView(symbol: icon.symbol, color: icon.color, size: 24) }
            }
        }
    }
}
