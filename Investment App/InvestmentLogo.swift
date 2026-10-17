//
//  InvestmentLogo.swift
//  Investment App
//
//  Created by Mohammed Elrashidy on 17/10/2026.
//

import SwiftUI
import UIKit

/// Company and coin logos for investments, fetched by ticker and cached in memory and on disk.
/// Stocks/ETFs come from Parqet (understands Yahoo suffixes like ".L", ".DE"); crypto from CoinCap.
@MainActor
final class LogoCache {
    static let shared = LogoCache()

    private var images: [String: UIImage] = [:]
    /// Symbols with no logo this session, so they aren't requested again on every scroll.
    private var missing = Set<String>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private let directory: URL? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = caches.appendingPathComponent("Logos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Where the logo for an investment lives, or nil if it has no symbol that a logo can be found for.
    static func logoURL(symbol: String?, category: String) -> URL? {
        guard let symbol = symbol?.trimmingCharacters(in: .whitespaces).uppercased(), !symbol.isEmpty,
              !symbol.contains("=") // futures (GC=F) and FX pairs have no logo
        else { return nil }

        let isCrypto = category.lowercased() == "crypto" || symbol.hasSuffix("-USD") || symbol.hasSuffix("-GBP")
        if isCrypto {
            // "BTC-USD" → "btc"; Yahoo's numeric ids like "SUI20947-USD" → "sui"
            let base = symbol.split(separator: "-").first.map(String.init) ?? symbol
            let coin = base.replacing(/\d+$/, with: "").lowercased()
            guard !coin.isEmpty else { return nil }
            return URL(string: "https://assets.coincap.io/assets/icons/\(coin)@2x.png")
        }
        guard let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://assets.parqet.com/logos/symbol/\(encoded)?format=png")
    }

    /// Already-loaded logo, for drawing without a flash of the placeholder.
    func cachedImage(for url: URL) -> UIImage? {
        images[url.absoluteString]
    }

    func image(for url: URL) async -> UIImage? {
        let key = url.absoluteString
        if let image = images[key] { return image }
        if missing.contains(key) { return nil }
        if let task = inFlight[key] { return await task.value }

        let fileURL = directory?.appendingPathComponent(Self.fileName(for: key))
        let task = Task<UIImage?, Never> {
            if let fileURL, let data = try? Data(contentsOf: fileURL), let image = UIImage(data: data) {
                return image
            }
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: data)
            else { return nil }
            if let fileURL {
                try? data.write(to: fileURL)
            }
            return image
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            images[key] = image
        } else if !Task.isCancelled {
            missing.insert(key)
        }
        return image
    }

    /// A filesystem-safe name for a URL.
    private static func fileName(for key: String) -> String {
        key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined() + ".png"
    }
}

/// The investment's logo, falling back to its category icon while loading or when there's no logo.
struct InvestmentLogoView: View {
    let symbol: String?
    let category: String
    var size: CGFloat = 24

    @State private var image: UIImage?

    private var url: URL? {
        LogoCache.logoURL(symbol: symbol, category: category)
    }

    var body: some View {
        Group {
            if let image = image ?? url.flatMap({ LogoCache.shared.cachedImage(for: $0) }) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.28))
                    .accessibilityHidden(true)
            } else {
                let icon = AssetIcons.category(category)
                AssetIconView(symbol: icon.symbol, color: icon.color, size: size)
            }
        }
        .task(id: url) {
            image = nil
            guard let url else { return }
            image = await LogoCache.shared.image(for: url)
        }
    }
}

#Preview("Logos") {
    let samples: [(name: String, symbol: String?, category: String)] = [
        ("Alphabet", "GOOGL", "Stock"), ("Apple", "AAPL", "Stock"), ("BP", "BP.L", "Stock"),
        ("Volkswagen", "VOW3.DE", "Stock"), ("Vanguard S&P 500", "VUSA.L", "ETF"),
        ("Bitcoin", "BTC-USD", "Crypto"), ("SUI", "SUI20947-USD", "Crypto"),
        ("Gold", "GC=F", "Commodity"), ("Cash", nil, "Cash"),
    ]
    List(samples, id: \.name) { sample in
        Label {
            Text("\(sample.name) (\(sample.symbol ?? "—"))")
        } icon: {
            InvestmentLogoView(symbol: sample.symbol, category: sample.category, size: 28)
        }
    }
}
