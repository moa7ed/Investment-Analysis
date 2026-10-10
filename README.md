# Investment App

A native iOS portfolio tracker built with SwiftUI that aggregates investments across multiple brokers and account types into a single view. It uses **Yahoo Finance** for live market prices and **Claude AI** for statement parsing and sector classification.

## Features

### Portfolio Overview
- Displays total portfolio value in GBP with automatic multi-currency conversion
- Sector-based bar chart showing current vs target allocation percentages
- Expandable sector groups revealing individual investments
- Color-coded indicators (green/red) for over/under-allocated positions
- GBP difference shown for each investment and sector against target allocation

### Statement Import (AI-Powered)
- Import broker statements as PDF, PNG, or JPEG files
- Claude AI extracts investment data: name, symbol, shares, price, value, currency, category, broker, and account type
- Preview screen shows matched/new/updated investments before applying
- Cash entries from the same broker are automatically consolidated into a single GBP holding regardless of account type (ISA, Invest, etc.)
- Symbols are stored without exchange suffixes (e.g. `VUSA` not `VUSA.L`) for cleaner data

### AI Sector Classification
- Claude AI groups investments into sectors (Tech, Crypto, Commodities, Index Funds, etc.)
- Incremental classification: only new/unclassified investments are sent to Claude
- Full reclassification available via the menu with configurable max sectors and custom instructions

### Live Price Fetching
- Concurrent price fetching from Yahoo Finance's chart API for all investments with symbols
- Automatic exchange suffix fallback: if a bare symbol fails (e.g. `VUSA`), retries with `.L`, `.DE`, `.PA`, `.AS`, `.MI`, `.SW`
- Dynamic exchange rate fetching for all currencies in the portfolio (via Yahoo Finance forex pairs like `USDGBP=X`)
- GBX (British pence) handled as a hardcoded 0.01 rate since it's not a real forex pair

### Investment Editing
- Edit name, symbol, manual price override, currency, holdings, manual value override, target allocation %, and sector
- Computed value displayed in both native currency and GBP
- Support for multiple holdings per investment (different brokers and account types)

## Architecture

### Data Model

**`Investment`** (`Investment.swift`)
- `Identifiable`, `Codable`, `Hashable` struct
- Supports API-fetched prices (`apiPrice`), manual price overrides (`manualPrice`), and direct value overrides (`manualValue`)
- `totalValue` computed property: `manualValue ?? (effectivePrice ?? 0) * totalShares`
- `effectivePrice`: `manualPrice ?? apiPrice`
- Holdings array tracks shares across multiple broker/account type combinations

**`Holding`** — nested struct with broker name, account type, and share count

**`ParsedStatementEntry`** — `Decodable` struct representing a single entry parsed from a broker statement by Claude

### State Management

**`PortfolioStore`** (`PortfolioStore.swift`)
- `@Observable` class annotated with `@MainActor`
- Persists to `UserDefaults` via JSON encoding/decoding
- Uses Swift concurrency (`async/await`, `withTaskGroup`) for concurrent API calls
- No Combine framework — uses Swift's native concurrency throughout

### Key Flows

**Price Refresh** (`fetchAllPrices`):
1. Cancels any in-flight fetch task
2. Concurrently fetches exchange rates and stock prices via `withTaskGroup`
3. Classifies any unclassified sectors via Claude
4. Saves to UserDefaults

**Statement Import**:
1. User selects a PDF/image file
2. File is base64-encoded and sent to Claude with extraction instructions
3. Claude returns a JSON array of parsed entries
4. Preview screen aggregates cash entries per broker and shows diffs against existing data
5. On apply: holdings are upserted, new investments created, then `fetchAllPrices()` runs

**Currency Conversion** (`valueInGBP`):
- All values are converted to GBP using dynamically fetched exchange rates
- `exchangeRates` dictionary is seeded with `GBP: 1.0` and `GBX: 0.01`, then populated at runtime for all currencies present in the portfolio

### External APIs

| API | Purpose | Authentication |
|-----|---------|----------------|
| Yahoo Finance Chart API | Stock prices, forex rates | None (public, User-Agent header) |
| Anthropic Messages API | Statement parsing, sector classification | API key via `Secrets.plist` |

### File Structure

```
Investment App/
  Investment.swift          # Data model (Investment, Holding)
  PortfolioStore.swift      # Business logic, API clients, persistence
  ContentView.swift         # Main UI (portfolio view, sector chart, toolbar)
  EditInvestmentView.swift  # Investment editing form
  StatementImportView.swift # Import preview and diff UI
  Investment_AppApp.swift   # App entry point
  Secrets.plist             # API key (git-ignored)
```

## Setup

1. Clone the repository
2. Create `Investment App/Secrets.plist` with your Anthropic API key:
   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
     "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0">
   <dict>
       <key>CLAUDE_API_KEY</key>
       <string>your-api-key-here</string>
   </dict>
   </plist>
   ```
3. Open `Investment App.xcodeproj` in Xcode
4. Build and run on an iOS device or simulator

## Requirements

- iOS 17+
- Xcode 15+
- Anthropic API key (for statement import and sector classification)
