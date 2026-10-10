//
//  SettingsView.swift
//  Investment App
//
//  Created by Mohammed Elrashidy on 10/10/2026.
//

import SwiftUI

struct SettingsView: View {
    @State private var keyText = ""
    @State private var savedKey = APIKeyStore.claudeKey
    @State private var showSaveError = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let savedKey {
                        LabeledContent("Saved Key", value: masked(savedKey))
                    } else {
                        Text("No API key saved. Statement import and sector classification need one.")
                            .foregroundStyle(.secondary)
                    }

                    SecureField(savedKey == nil ? "Paste API key" : "Paste a new key to replace it", text: $keyText)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Button("Save Key") {
                        let trimmed = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if APIKeyStore.saveClaudeKey(trimmed) {
                            savedKey = trimmed
                            keyText = ""
                        } else {
                            showSaveError = true
                        }
                    }
                    .disabled(keyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if savedKey != nil {
                        Button("Remove Key", role: .destructive) {
                            APIKeyStore.deleteClaudeKey()
                            savedKey = nil
                        }
                    }
                } header: {
                    Text("Claude API Key")
                } footer: {
                    Text("Stored securely in this device's Keychain. It is never included in the app bundle.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Couldn't Save Key", isPresented: $showSaveError) {
                Button("OK") { }
            } message: {
                Text("The key could not be written to the Keychain. Please try again.")
            }
        }
    }

    /// Shows only the last 4 characters, e.g. "••••••••abcd".
    private func masked(_ key: String) -> String {
        "••••••••" + key.suffix(4)
    }
}

#Preview {
    SettingsView()
}
