import SwiftUI
import UIKit

/// Both halves of adding a friend: your own code to hand out, and a field for theirs.
///
/// There are no accounts, so the code *is* the identity — which makes sharing it the
/// primary action on this sheet rather than a footnote under the input field.
struct AddFriendSheet: View {
    let social: SocialService
    let myCode: String

    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var isSubmitting = false
    @State private var didCopy = false

    private var shareMessage: String {
        "Add me on ParkMax — my friend code is \(myCode)."
    }

    /// Nil while the field is incomplete: half-typed codes shouldn't read as errors.
    private var inlineError: String? {
        guard code.count == 6 else { return nil }
        if code == myCode.uppercased() { return "That's your own code. Share it with a friend instead." }
        return nil
    }

    private var canSubmit: Bool {
        code.count == 6 && inlineError == nil && !isSubmitting
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.sectionSpacing) {
                    myCodeCard
                    enterCodeCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .background(Theme.background)
            .navigationTitle("Add Friend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: - Your code

    private var myCodeCard: some View {
        VStack(spacing: 16) {
            Text("Your friend code")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                .textCase(.uppercase)

            Text(myCode)
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospaced()
                .kerning(6)
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .accessibilityLabel("Your friend code is \(spelledOut(myCode))")

            HStack(spacing: 10) {
                Button {
                    UIPasteboard.general.string = myCode
                    withAnimation(.smooth(duration: 0.25)) { didCopy = true }
                } label: {
                    Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textPrimary)
                .accessibilityLabel("Copy your friend code")

                ShareLink(item: shareMessage) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textPrimary)
            }

            Text("Anyone with this code can see your summary numbers and the visits you share.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Theme.heroGradient, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    // MARK: - Their code

    private var enterCodeCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader("Add someone", subtitle: "Enter the 6-character code they gave you")

                TextField("ABC123", text: $code)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospaced()
                    .kerning(4)
                    .multilineTextAlignment(.center)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .textContentType(.oneTimeCode)
                    .padding(.vertical, 14)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.tightCornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.tightCornerRadius, style: .continuous)
                            .strokeBorder(inlineError == nil ? Theme.separator : Color.red.opacity(0.6), lineWidth: 1)
                    )
                    .onChange(of: code) { _, newValue in
                        let cleaned = String(
                            newValue.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(6)
                        )
                        if cleaned != code { code = cleaned }
                    }
                    .accessibilityLabel("Friend code")

                HStack {
                    Text("\(code.count)/6")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    if social.isSyncing || isSubmitting {
                        ProgressView().controlSize(.small)
                    }
                }

                if let message = inlineError ?? social.lastError, !message.isEmpty {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    Task { await submit() }
                } label: {
                    Text("Add friend")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(!canSubmit)
            }
        }
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        if await social.addFriend(code: code) {
            dismiss()
        }
    }

    /// VoiceOver reads a run of letters and digits as a word; spelling it out makes a
    /// code someone can actually repeat over the phone.
    private func spelledOut(_ value: String) -> String {
        value.map(String.init).joined(separator: " ")
    }
}
