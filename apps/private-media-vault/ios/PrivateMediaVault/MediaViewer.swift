import AVFoundation
import AVKit
import SwiftUI
import VaultCore

struct MediaViewer: View {
    @Environment(VaultModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let startID: UUID
    var queue: [UUID]? = nil

    @State private var index = 0
    @State private var playback = PlaybackSession()

    private var ids: [UUID] { queue ?? model.items.map(\.id) }
    private var currentItem: MediaItem? {
        guard ids.indices.contains(index) else { return nil }
        return model.items.first { $0.id == ids[index] }
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $index) {
                ForEach(Array(ids.enumerated()), id: \.offset) { offset, id in
                    ViewerPage(id: id, active: offset == index, player: playback.player)
                        .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .background(VaultTheme.background)
            .navigationTitle(currentItem?.originalFilename ?? "Media")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        playback.stop(savingWith: model)
                        dismiss()
                    }
                    .frame(minHeight: 44)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(playback.continuous ? "Continuous on" : "Continuous off") {
                        playback.continuous.toggle()
                        model.setContinuous(playback.continuous)
                    }
                    .frame(minHeight: 44)
                }
            }
        }
        .onAppear {
            playback.continuous = model.continuousPlayback
            index = ids.firstIndex(of: startID) ?? 0
            playback.open(item: currentItem, model: model)
        }
        .onChange(of: index) { _, _ in
            playback.open(item: currentItem, model: model)
        }
        .onChange(of: playback.endedCount) { _, _ in
            advance()
        }
        .onDisappear { playback.stop(savingWith: model) }
    }

    private func advance() {
        guard playback.continuous, index + 1 < ids.count else { return }
        index += 1
    }
}

struct ViewerPage: View {
    @Environment(VaultModel.self) private var model
    let id: UUID
    let active: Bool
    let player: AVPlayer?
    @State private var still: UIImage?

    var body: some View {
        let item = model.items.first { $0.id == id }
        Group {
            if let item, item.mediaKind == .video || item.mediaKind == .livePhoto {
                if active, let player {
                    VideoPlayerSurface(player: player)
                } else {
                    thumbnail
                }
            } else if let still {
                Image(uiImage: still)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel(item?.caption.isEmpty == false ? item?.caption ?? "" : item?.originalFilename ?? "Image")
            } else {
                thumbnail
            }
        }
        .task(id: id) {
            guard item?.mediaKind != .video, item?.mediaKind != .livePhoto else { return }
            if let data = model.imageData(for: id) {
                still = UIImage(data: data)
            }
        }
    }

    private var thumbnail: some View {
        ZStack {
            VaultTheme.card
            if let data = model.thumbnail(for: id), let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(VaultTheme.accent)
            }
        }
    }
}

struct VideoPlayerSurface: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}

@MainActor
@Observable
final class PlaybackSession {
    var player: AVPlayer?
    var continuous = true
    var endedCount = 0
    private var loader: EncryptedVideoLoader?
    private var reader: ChunkedReader?
    private var observer: NSObjectProtocol?
    private var timeToken: Any?
    private var itemID: UUID?

    func open(item: MediaItem?, model: VaultModel) {
        stop(savingWith: model)
        guard let item else { return }
        guard item.mediaKind == .video || item.mediaKind == .livePhoto else { return }
        do {
            let opened: ChunkedReader
            if item.mediaKind == .livePhoto, let motion = try model.liveMotion(for: item.id) {
                opened = motion
            } else {
                opened = try model.reader(for: item.id)
            }
            reader = opened
            itemID = item.id
            let bridge = EncryptedVideoLoader(reader: opened, contentType: item.contentTypeIdentifier)
            loader = bridge
            let avPlayer = AVPlayer(playerItem: AVPlayerItem(asset: bridge.makeAsset(for: item.id)))
            if let resume = item.resumeSeconds, resume > 0.25 {
                avPlayer.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
            }
            observer = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: avPlayer.currentItem,
                queue: .main
            ) { _ in
                Task { @MainActor in self.endedCount += 1 }
            }
            let interval = CMTime(seconds: 1, preferredTimescale: 1)
            timeToken = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
                let duration = avPlayer.currentItem?.duration.seconds
                Task { @MainActor in
                    model.saveResume(
                        id: item.id,
                        seconds: time.seconds.isFinite ? time.seconds : 0,
                        duration: duration?.isFinite == true ? duration : nil
                    )
                }
            }
            avPlayer.play()
            player = avPlayer
        } catch {
            model.statusMessage = publicMessage(error)
        }
    }

    func stop(savingWith model: VaultModel) {
        if let itemID, let seconds = player?.currentTime().seconds, seconds.isFinite {
            model.saveResume(id: itemID, seconds: seconds, duration: player?.currentItem?.duration.seconds)
        }
        if let token = timeToken { player?.removeTimeObserver(token) }
        timeToken = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        player?.pause()
        player = nil
        loader = nil
        reader?.close()
        reader = nil
        itemID = nil
    }
}
