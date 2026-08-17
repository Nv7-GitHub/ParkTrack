import SwiftUI
import AVKit
import UIKit

/// Full-screen photo or video from a friend's shared visit.
///
/// Media arrives as raw bytes and `AVPlayer` only plays from a URL, so video is
/// spilled to a temporary file for the lifetime of the viewer and removed on the way
/// out — nothing shared by a friend is kept on disk beyond the local mirror.
struct FriendMediaViewer: View {
    let visit: FriendVisit

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var videoURL: URL?
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            media
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.primary)
                            .padding(12)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("Close")
                }
                Spacer()
                caption
            }
            .padding(16)
        }
        .task { await prepareVideo() }
        .onDisappear(perform: tearDown)
    }

    @ViewBuilder
    private var media: some View {
        if visit.mediaIsVideo {
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }
        } else if let data = visit.mediaData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            scale = min(max(1, baseScale * value.magnification), 5)
                        }
                        .onEnded { _ in baseScale = scale }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.smooth(duration: 0.3)) {
                        scale = 1
                        baseScale = 1
                    }
                }
                .accessibilityLabel("Photo from \(visit.parkName)")
        } else {
            Text("This attachment couldn't be opened.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(visit.parkName)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            HStack(spacing: 8) {
                if let name = visit.friend?.displayName, !name.isEmpty {
                    Text(name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                Text(Format.date(visit.date))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            if !visit.note.isEmpty {
                Text(visit.note)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    private func prepareVideo() async {
        guard visit.mediaIsVideo, let data = visit.mediaData, !data.isEmpty, player == nil else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("friend-media-\(UUID().uuidString)")
            .appendingPathExtension("mp4")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }
        videoURL = url
        let player = AVPlayer(url: url)
        self.player = player
        player.play()
    }

    private func tearDown() {
        player?.pause()
        player = nil
        if let videoURL {
            try? FileManager.default.removeItem(at: videoURL)
        }
        videoURL = nil
    }
}
