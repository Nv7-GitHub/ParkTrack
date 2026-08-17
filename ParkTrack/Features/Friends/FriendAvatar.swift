import SwiftUI

/// Initials in a tinted circle, used wherever a friend is named.
///
/// Friends have no photos by design — nothing about a person is shared beyond a name,
/// a code and their numbers — so identity is carried by initials and a colour derived
/// deterministically from the name, which keeps the same person the same colour
/// everywhere in the app.
struct FriendAvatar: View {
    let name: String
    var isMe: Bool = false
    var size: CGFloat = 34

    private var initials: String {
        let parts = name
            .split(whereSeparator: { $0 == " " || $0 == "-" })
            .prefix(2)
            .compactMap { $0.first }
        let letters = String(parts).uppercased()
        return letters.isEmpty ? "?" : letters
    }

    private var tint: Color {
        guard !isMe else { return Theme.accent }
        let hash = abs(name.unicodeScalars.reduce(into: 5_381) { $0 = $0 &* 33 &+ Int($1.value) })
        return Theme.chartColors[hash % Theme.chartColors.count]
    }

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.16), in: Circle())
            .overlay(Circle().strokeBorder(tint.opacity(isMe ? 0.6 : 0.25), lineWidth: isMe ? 1.5 : 1))
            .accessibilityHidden(true)
    }
}
