import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import VaultCore

struct LibraryShell: View {
    @Environment(VaultModel.self) private var model
    @State private var selection = Set<UUID>()
    @State private var selecting = false
    @State private var showViewer = false
    @State private var viewerID: UUID?

    var body: some View {
        TabView {
            NavigationStack {
                LibraryGrid(selection: $selection, selecting: $selecting, viewerID: $viewerID, showViewer: $showViewer)
            }
            .tabItem { Label("Library", systemImage: "square.grid.2x2") }

            NavigationStack { AlbumsView() }
                .tabItem { Label("Albums", systemImage: "rectangle.stack") }

            NavigationStack { PlaylistsView() }
                .tabItem { Label("Playlists", systemImage: "music.note.list") }

            NavigationStack { MoreView() }
                .tabItem { Label("More", systemImage: "ellipsis.circle") }
        }
        .tint(VaultTheme.accent)
        .fullScreenCover(isPresented: $showViewer) {
            if let viewerID {
                MediaViewer(startID: viewerID)
            }
        }
    }
}

struct LibraryGrid: View {
    @Environment(VaultModel.self) private var model
    @Binding var selection: Set<UUID>
    @Binding var selecting: Bool
    @Binding var viewerID: UUID?
    @Binding var showViewer: Bool
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showCamera = false
    @State private var showLink = false
    @State private var pickerItems: [PhotosPickerItem] = []

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 8)]

    var body: some View {
        ScrollView {
            if let statusMessage = model.statusMessage {
                Text(statusMessage)
                    .font(.callout)
                    .foregroundStyle(VaultTheme.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .accessibilityLabel(statusMessage)
            }
            if model.items.isEmpty {
                ContentUnavailableView(
                    "No media yet",
                    systemImage: "lock.rectangle.stack",
                    description: Text("Import from Photos, Files, or the camera. Nothing is deleted from the place it came from.")
                )
                .frame(minHeight: 240)
            }
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(model.items) { item in
                    Button {
                        if selecting {
                            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
                        } else {
                            viewerID = item.id
                            showViewer = true
                        }
                    } label: {
                        ThumbnailCell(item: item, selected: selection.contains(item.id))
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 108)
                    .accessibilityLabel(item.originalFilename)
                    .accessibilityAddTraits(item.favorite ? .isSelected : [])
                }
            }
            .padding(12)
        }
        .background(VaultTheme.background)
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(selecting ? "Done" : "Select") {
                    selecting.toggle()
                    if !selecting { selection.removeAll() }
                }
                .frame(minHeight: 44)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Photos") { showPhotos = true }
                    Button("Files") { showFiles = true }
                    Button("Camera") { showCamera = true }
                    Button("Link") { showLink = true }
                } label: {
                    Image(systemName: "plus")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Import")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if selecting, !selection.isEmpty {
                BulkBar(ids: Array(selection))
            }
        }
        .photosPicker(isPresented: $showPhotos, selection: $pickerItems, matching: .any(of: [.images, .videos, .livePhotos]))
        .onChange(of: pickerItems) { _, items in
            Task { await importPhotos(items) }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image, .movie, .video], allowsMultipleSelection: true) { result in
            importFiles(result)
        }
        .sheet(isPresented: $showCamera) { CameraCaptureView() }
        .sheet(isPresented: $showLink) { LinkImportView() }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            do {
                let image = try? await item.loadTransferable(type: PickedImage.self)
                let video = try? await item.loadTransferable(type: PickedVideo.self)
                if let image, let video {
                    try model.importFile(image.url, source: .photosPicker, liveMotion: video.url)
                    try? FileManager.default.removeItem(at: image.url)
                    try? FileManager.default.removeItem(at: video.url)
                } else if let video {
                    try model.importFile(video.url, source: .photosPicker)
                    try? FileManager.default.removeItem(at: video.url)
                } else if let image {
                    try model.importFile(image.url, source: .photosPicker)
                    try? FileManager.default.removeItem(at: image.url)
                } else {
                    model.statusMessage = "The selected item did not include a readable image or video."
                }
            } catch {
                model.statusMessage = publicMessage(error)
            }
        }
        pickerItems = []
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            model.statusMessage = publicMessage(error)
        case .success(let urls):
            for url in urls {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                do { try model.importFile(url, source: .files) }
                catch { model.statusMessage = publicMessage(error) }
            }
        }
    }
}

struct ThumbnailCell: View {
    @Environment(VaultModel.self) private var model
    let item: MediaItem
    let selected: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let data = model.thumbnail(for: item.id), let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                VaultTheme.card
                Image(systemName: item.mediaKind == .video ? "video" : "photo")
                    .foregroundStyle(VaultTheme.accent)
            }
            if item.favorite {
                Image(systemName: "heart.fill")
                    .padding(6)
                    .foregroundStyle(VaultTheme.accent)
                    .accessibilityLabel("Favourite")
            }
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .padding(6)
            }
        }
        .frame(height: 108)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct BulkBar: View {
    @Environment(VaultModel.self) private var model
    let ids: [UUID]
    @State private var albumID: UUID?

    var body: some View {
        HStack {
            Button("Favourite") { model.toggleFavorite(ids) }
                .frame(minHeight: 44)
                .accessibilityHint("Toggles the favourite mark on the selected items")
            Menu("Album") {
                ForEach(model.albums) { album in
                    Button(album.name) { model.add(ids, to: album.id) }
                }
            }
            .accessibilityLabel("Add selected items to an album")
            Button("Trash") { model.trash(ids) }
                .frame(minHeight: 44)
                .accessibilityHint("Moves the selected items to trash. Restore them from Trash until they are purged.")
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .padding(.horizontal)
        .background(.ultraThinMaterial)
    }
}

struct AlbumsView: View {
    @Environment(VaultModel.self) private var model
    @State private var name = ""

    var body: some View {
        List {
            Section("New album") {
                TextField("Album name", text: $name)
                Button("Create album") {
                    model.createAlbum(name)
                    name = ""
                }
                .frame(minHeight: 44)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section("Albums") {
                ForEach(model.albums) { album in
                    NavigationLink(album.name) {
                        AlbumDetail(album: album)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(VaultTheme.background)
        .navigationTitle("Albums")
    }
}

struct AlbumDetail: View {
    @Environment(VaultModel.self) private var model
    let album: Album

    var body: some View {
        let items = model.items.filter { $0.albumIDs.contains(album.id) }
        List(items) { item in
            Text(item.originalFilename)
        }
        .navigationTitle(album.name)
        .scrollContentBackground(.hidden)
        .background(VaultTheme.background)
    }
}

struct PlaylistsView: View {
    @Environment(VaultModel.self) private var model
    @State private var name = ""

    var body: some View {
        List {
            Section("New playlist") {
                TextField("Playlist name", text: $name)
                Button("Create from current library order") {
                    model.createPlaylist(name, ids: model.items.map(\.id))
                    name = ""
                }
                .frame(minHeight: 44)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ForEach(model.playlists) { playlist in
                NavigationLink(playlist.name) {
                    PlaylistDetail(playlist: playlist)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(VaultTheme.background)
        .navigationTitle("Playlists")
    }
}

struct PlaylistDetail: View {
    let playlist: Playlist
    @State private var show = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(playlist.itemIDs.count) items")
            Button("Play continuously") { show = true }
                .frame(minHeight: 44)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(VaultTheme.background)
        .navigationTitle(playlist.name)
        .fullScreenCover(isPresented: $show) {
            if let first = playlist.itemIDs.first {
                MediaViewer(startID: first, queue: playlist.itemIDs)
            }
        }
    }
}
