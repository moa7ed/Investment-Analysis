//
//  BrokerLogo.swift
//  Investment App
//
//  Created by Mohammed Elrashidy on 18/10/2026.
//

import SwiftUI

/// Logos for brokers and platforms. Broker names are free text, so well-known ones are matched to their
/// website and shown with its icon; anything else gets a coloured monogram.
enum BrokerLogos {
    /// Normalised name keys (lowercased letters and digits) → website. Keys of three letters or fewer must match
    /// the whole name ("hl", "ii", "ig"); longer keys may appear anywhere in it ("trading212invest").
    private static let domains: [(key: String, domain: String)] = [
        ("trading212", "trading212.com"),
        ("revolut", "revolut.com"),
        ("coinbase", "coinbase.com"),
        ("hargreaveslansdown", "hl.co.uk"),
        ("hl", "hl.co.uk"),
        ("ajbell", "ajbell.co.uk"),
        ("interactiveinvestor", "ii.co.uk"),
        ("ii", "ii.co.uk"),
        ("vanguard", "vanguardinvestor.co.uk"),
        ("freetrade", "freetrade.io"),
        ("etoro", "etoro.com"),
        ("interactivebrokers", "interactivebrokers.com"),
        ("ibkr", "interactivebrokers.com"),
        ("fidelity", "fidelity.co.uk"),
        ("investengine", "investengine.com"),
        ("lightyear", "lightyear.com"),
        ("moneybox", "moneyboxapp.com"),
        ("nutmeg", "nutmeg.com"),
        ("plum", "withplum.com"),
        ("chip", "getchip.uk"),
        ("wealthify", "wealthify.com"),
        ("ig", "ig.com"),
        ("saxo", "home.saxo"),
        ("kraken", "kraken.com"),
        ("binance", "binance.com"),
        ("cryptocom", "crypto.com"),
        ("bullionvault", "bullionvault.com"),
        ("royalmint", "royalmint.com"),
        ("monzo", "monzo.com"),
        ("wise", "wise.com"),
        ("barclays", "barclays.co.uk"),
        ("hsbc", "hsbc.co.uk"),
        ("lloyds", "lloydsbank.com"),
        ("halifax", "halifax.co.uk"),
        ("natwest", "natwest.com"),
        ("santander", "santander.co.uk"),
        ("nationwide", "nationwide.co.uk"),
        ("schwab", "schwab.com"),
        ("robinhood", "robinhood.com"),
    ]

    static func domain(for broker: String) -> String? {
        let key = PortfolioStore.normalizeBroker(broker)
        guard !key.isEmpty else { return nil }
        return domains.first { entry in
            entry.key.count <= 3 ? key == entry.key : key.contains(entry.key)
        }?.domain
    }

    /// The site's icon, via Google's favicon service (cached by `LogoCache` like investment logos).
    static func logoURL(for broker: String) -> URL? {
        domain(for: broker).flatMap { URL(string: "https://www.google.com/s2/favicons?domain=\($0)&sz=128") }
    }

    /// Up to two letters: the first letter of the first two words ("Trading 212" → "T2"),
    /// or the first two letters of a single word ("Revolut" → "RE").
    static func monogram(for broker: String) -> String {
        let words = broker.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let letters = words.count >= 2
            ? words.prefix(2).compactMap(\.first).map(String.init).joined()
            : String(words.first?.prefix(2) ?? "?")
        return letters.uppercased()
    }

    private static let monogramColors: [Color] = [.blue, .purple, .teal, .indigo, .pink, .orange, .mint, .brown]

    /// A colour that stays the same for a broker across launches (Swift's `hashValue` changes every launch).
    static func monogramColor(for broker: String) -> Color {
        let hash = PortfolioStore.normalizeBroker(broker).unicodeScalars
            .reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return monogramColors[Int(hash % UInt32(monogramColors.count))]
    }
}

extension BrokerLogos {
    /// The logo if it's loaded and big enough to look sharp; tiny favicons fall back to the monogram.
    @MainActor
    static func usableLogo(_ image: UIImage?) -> UIImage? {
        guard let image, image.size.width * image.scale >= 32 else { return nil }
        return image
    }

    /// Downloads (or reads from cache) the logos for these brokers, so menus can show them straight away.
    @MainActor
    static func preload(_ brokers: [String]) async {
        for url in brokers.compactMap(logoURL(for:)) {
            _ = await LogoCache.shared.image(for: url)
        }
    }

    /// Rendered icons for menus, keyed by broker and whether the logo was available.
    @MainActor
    private static var menuIcons: [String: UIImage] = [:]

    /// The broker's icon as a plain image — menus can't show custom views. Uses the logo if it's already
    /// cached (see `preload`), otherwise the monogram.
    @MainActor
    static func menuIcon(for broker: String, size: CGFloat = 22) -> UIImage? {
        let logo = usableLogo(logoURL(for: broker).flatMap { LogoCache.shared.cachedImage(for: $0) })
        let key = "\(PortfolioStore.normalizeBroker(broker))|\(logo != nil)|\(size)"
        if let cached = menuIcons[key] { return cached }

        let renderer = ImageRenderer(content: BrokerIconContent(broker: broker, logo: logo, size: size))
        renderer.scale = UITraitCollection.current.displayScale
        guard let image = renderer.uiImage?.withRenderingMode(.alwaysOriginal) else { return nil }
        menuIcons[key] = image
        return image
    }
}

/// The icon artwork: the logo on a white tile, or the monogram on a tinted tile.
private struct BrokerIconContent: View {
    let broker: String
    let logo: UIImage?
    let size: CGFloat

    var body: some View {
        if let logo {
            Image(uiImage: logo)
                .resizable()
                .scaledToFit()
                .padding(size * 0.08)
                .frame(width: size, height: size)
                .background(Color.white, in: RoundedRectangle(cornerRadius: size * 0.28))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.28)
                        .strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5)
                )
        } else {
            let color = BrokerLogos.monogramColor(for: broker)
            Text(BrokerLogos.monogram(for: broker))
                .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .frame(width: size, height: size)
                .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: size * 0.28))
        }
    }
}

/// A broker's logo, or its monogram while loading, offline, or when the broker isn't recognised.
struct BrokerIconView: View {
    let broker: String
    var size: CGFloat = 24

    @State private var image: UIImage?

    private var url: URL? {
        BrokerLogos.logoURL(for: broker)
    }

    var body: some View {
        BrokerIconContent(
            broker: broker,
            logo: BrokerLogos.usableLogo(image ?? url.flatMap { LogoCache.shared.cachedImage(for: $0) }),
            size: size
        )
        .accessibilityHidden(true)
        .task(id: url) {
            image = nil
            guard let url else { return }
            image = await LogoCache.shared.image(for: url)
        }
    }
}

/// A menu item label with the broker's icon (menus only show plain images, so the icon is pre-rendered).
struct BrokerMenuLabel: View {
    let broker: String

    var body: some View {
        if let icon = BrokerLogos.menuIcon(for: broker) {
            Label {
                Text(broker)
            } icon: {
                Image(uiImage: icon)
            }
        } else {
            Text(broker)
        }
    }
}

#Preview("Broker icons") {
    let brokers = ["Trading 212", "Revolut", "Coinbase", "Hargreaves Lansdown", "AJ Bell", "Freetrade",
                   "Vanguard", "Interactive Investor", "Some Local Broker", "Unknown"]
    List(brokers, id: \.self) { broker in
        Label {
            Text(broker)
        } icon: {
            BrokerIconView(broker: broker, size: 28)
        }
    }
}
