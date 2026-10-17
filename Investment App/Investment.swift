//
//  Investment.swift
//  Investment App
//
//  Created by Mohammed Elrashidy on 10/09/2026.
//

import Foundation

struct Holding: Codable, Hashable {
    var broker: String      // e.g. "Trading 212", "Revolut", "Coinbase"
    var accountType: String // e.g. "ISA", "Invest", "General"
    var shares: Double

    /// Account types offered in pickers. Holdings can still carry other types (e.g. from older imports).
    static let standardAccountTypes = ["ISA", "Invest", "General"]
}

struct Investment: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var symbol: String?
    var category: String
    var sector: String?
    var apiPrice: Double?
    var manualPrice: Double?
    var manualValue: Double?
    var currencyCode: String
    var holdings: [Holding]
    var targetPercentage: Double

    var totalShares: Double {
        holdings.reduce(0) { $0 + $1.shares }
    }

    var effectivePrice: Double? {
        manualPrice ?? apiPrice
    }

    var totalValue: Double {
        manualValue ?? (effectivePrice ?? 0) * totalShares
    }

    /// Fallback for UI — returns classified sector or "Unclassified" if not yet classified
    var sectorOrDefault: String {
        sector ?? "Unclassified"
    }

    init(
        name: String,
        symbol: String? = nil,
        category: String = "Stock",
        targetPercentage: Double = 0,
        currencyCode: String = "USD",
        manualValue: Double? = nil,
        holdings: [Holding] = []
    ) {
        self.id = UUID()
        self.name = name
        self.symbol = symbol
        self.category = category
        self.sector = nil
        self.targetPercentage = targetPercentage
        self.currencyCode = currencyCode
        self.apiPrice = nil
        self.manualPrice = nil
        self.manualValue = manualValue
        self.holdings = holdings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol)
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? "Stock"
        sector = try container.decodeIfPresent(String.self, forKey: .sector)
        apiPrice = try container.decodeIfPresent(Double.self, forKey: .apiPrice)
        manualPrice = try container.decodeIfPresent(Double.self, forKey: .manualPrice)
        manualValue = try container.decodeIfPresent(Double.self, forKey: .manualValue)
        currencyCode = try container.decodeIfPresent(String.self, forKey: .currencyCode) ?? "USD"
        holdings = try container.decodeIfPresent([Holding].self, forKey: .holdings) ?? []
        targetPercentage = try container.decodeIfPresent(Double.self, forKey: .targetPercentage) ?? 0
    }
}
