import SwiftUI
import Photos
import PhotosUI

struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: AppTab = .review
    private enum AppTab {
        case review, bin, settings
    }
    var body: some View {
        Group {
            if model.library.hasAccess {
                TabView(selection: $tab) {
                    Tab("Review", systemImage: "photo.stack", value: AppTab.review) {
                        NavigationStack {
                            SwipeView(model: model).navigationTitle("Review").navigationBarTitleDisplayMode(.inline)
                        }
                    }
                    Tab("Bin", systemImage: "trash", value: AppTab.bin) {
                        NavigationStack {
                            BinView(model: model).navigationTitle("Bin").navigationBarTitleDisplayMode(.inline)
                        }
                    }
                    Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                        NavigationStack {
                            SettingsView(model: model).navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
                        }
                    }
                }
            } else { PermissionView(model: model) }
        }
        .fullScreenCover(item: $model.fullscreenAsset) { FullscreenPreview(asset: $0, library: model.library) }
        .sheet(item: $model.photoSheet) { sheet in
            switch sheet {
            case .compression(let asset): CompressionView(model: model, asset: asset)
            case .info(let asset): PhotoInfoView(asset: asset, library: model.library)
            case .compressionReport(let result): CompressionReportView(result: result)
            }
        }
        .buttonStyle(PhotoActionStyle())
        .task { await model.library.refresh(); await model.reconcile() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.library.refresh(); await model.reconcile() } }
        }
        .onChange(of: model.library.revision) { _, _ in
            Task { await model.reconcile() }
            if !model.library.hasAccess { model.photoSheet = nil; model.fullscreenAsset = nil }
        }
        .alert("Unable to finish", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

struct PermissionView: View {
    @Bindable var model: AppModel
    @State private var requesting = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Label("Swipix", systemImage: "rectangle.stack.fill")
                    .font(.headline)
                Spacer(minLength: 30)
                Image(systemName: "photo.on.rectangle.angled").font(.system(size: 72, weight: .light)).foregroundStyle(Color.green)
                Text("Make room for\nwhat matters.").font(.largeTitle.bold())
                    .minimumScaleFactor(0.7)
                Text("Review your photos one at a time. Keep the good ones. Put the others in your Bin to decide later.")
                    .font(.title3).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 14) {
                    Label("Swiping never deletes a photo", systemImage: "checkmark.shield")
                    Label("Choose all photos or a limited selection", systemImage: "photo.badge.checkmark")
                    Label("Processing stays on your iPhone", systemImage: "iphone")
                }.font(.subheadline)
                if model.library.authorization == .denied || model.library.authorization == .restricted {
                    Text("Photos access is unavailable. Allow access in Settings to review your library.").foregroundStyle(Color.red)
                    Button("Open Settings") { openSettings() }.buttonStyle(PhotoActionStyle(color: .blue))
                } else {
                    Button {
                        requesting = true
                        Task { await model.library.requestAccess(); requesting = false }
                    } label: {
                        HStack { Text("Choose Photos access"); if requesting { ProgressView().tint(.white) } }
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                    }.buttonStyle(PhotoActionStyle(color: .blue)).disabled(requesting)
                }
                Text("Swipix needs read/write access to show your selection, save compressed copies, and delete only the photos you explicitly confirm. iCloud originals may be downloaded by Photos.")
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding(28).frame(maxWidth: 580, alignment: .leading)
        }.background(Color(uiColor: .systemBackground))
    }
}

struct SwipeView: View {
    @Bindable var model: AppModel
    @Environment(\.displayScale) private var scale
    var body: some View {
        GeometryReader { geometry in
            let ratio = min(1, 1600 / max(geometry.size.width * scale, geometry.size.height * scale))
            let size = CGSize(width: geometry.size.width * scale * ratio, height: geometry.size.height * scale * ratio)
            VStack(spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Review photos").font(.title2.bold())
                        Text("\(model.remainingCount) to review · \(model.store.binIDs.count) in Bin").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward").font(.title3) }
                        .buttonStyle(PhotoActionStyle(compact: true)).buttonBorderShape(.circle).accessibilityLabel("Undo last decision").disabled(model.store.lastDecision == nil || model.deleting || model.updatingReview)
                }
                if model.library.authorization == .limited {
                    HStack {
                        Label("Selected photos only", systemImage: "photo.badge.checkmark").font(.caption)
                        Spacer()
                        LimitedLibraryButton { Task { await model.library.refresh() } }.font(.caption.weight(.semibold))
                    }
                }
                if let asset = model.current {
                    SwipeCard(asset: asset, following: Array(model.upcoming.dropFirst().prefix(2)), library: model.library, targetSize: size,
                              decide: { await model.decide(asset, $0) }, compress: { model.photoSheet = .compression(asset) }, fullscreen: { model.fullscreenAsset = asset }, info: { model.photoSheet = .info(asset) })
                        .id(asset.localIdentifier)
                        .zIndex(1)
                } else {
                    ContentUnavailableView {
                        Label(model.library.assets.isEmpty ? "No photos available" : "You're all caught up", systemImage: "checkmark.rectangle.stack")
                    } description: {
                        Text(model.library.assets.isEmpty ? "Add photos to your library or change your selected Photos access." : "Your decisions are saved. Restore a photo from the Bin to review it again, or come back when you add more.")
                    } actions: {
                        if model.library.authorization == .limited { LimitedLibraryButton { Task { await model.library.refresh() } } }
                        Button("Refresh library") { Task { await model.library.refresh() } }
                    }.frame(maxHeight: .infinity)
                }
                Text("Left → Bin    ·    Right → Keep").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).padding(.vertical, 12)
                .onChange(of: model.current?.localIdentifier, initial: true) { _, _ in
                    model.library.prefetch(model.upcoming, size: size)
                }
                .onChange(of: model.library.revision) { _, _ in model.library.prefetch(model.upcoming, size: size) }
                .onChange(of: geometry.size) { _, _ in model.library.prefetch(model.upcoming, size: size) }
        }
        .background(Color(uiColor: .systemBackground))
        .safeAreaInset(edge: .top) {
            if let result = model.compressionNotice {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Compressed photo kept · Original in Bin").font(.subheadline.weight(.semibold))
                        Label(result.metadata.differences.isEmpty ? "Some metadata cannot be guaranteed" : "\(result.metadata.differences.count) metadata fields changed or missing",
                              systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button { model.photoSheet = .compressionReport(result) } label: { Image(systemName: "info") }
                        .buttonStyle(PhotoActionStyle(compact: true)).buttonBorderShape(.circle).accessibilityLabel("Compression details")
                    Button { model.compressionNotice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(PhotoActionStyle(compact: true)).buttonBorderShape(.circle).accessibilityLabel("Dismiss compression notice")
                }.padding().background(.bar).accessibilityIdentifier("compression-notice")
            }
        }
    }
}

extension PHAsset: @retroactive Identifiable { public var id: String { localIdentifier } }

struct SwipeCard: View {
    let asset: PHAsset
    let following: [PHAsset]
    let library: PhotoLibraryService
    let targetSize: CGSize
    let decide: (ReviewChoice) async -> Void
    let compress: () -> Void
    let fullscreen: () -> Void
    let info: () -> Void
    init(asset: PHAsset, following: [PHAsset], library: PhotoLibraryService, targetSize: CGSize,
         decide: @escaping (ReviewChoice) async -> Void, compress: @escaping () -> Void, fullscreen: @escaping () -> Void, info: @escaping () -> Void) {
        self.asset = asset; self.following = following; self.library = library; self.targetSize = targetSize
        self.decide = decide; self.compress = compress; self.fullscreen = fullscreen; self.info = info
        _image = State(initialValue: library.cachedPreview(asset))
    }
    @State private var advance: Task<Void, Never>?
    @State private var image: UIImage?
    @State private var fileSize = "Reading original size…"
    @State private var failure: String?
    @State private var offset = CGSize.zero
    @State private var committing = false
    @State private var retry = 0
    @State private var sizeRetry = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                ForEach(Array(following.enumerated()).reversed(), id: \.element.localIdentifier) { index, next in
                    StackedPhoto(asset: next, library: library, targetSize: targetSize)
                        .scaleEffect(1 - CGFloat(index + 1) * 0.035)
                        .offset(y: CGFloat(index + 1) * 10)
                        .accessibilityHidden(true)
                }
                ZStack {
                    RoundedRectangle(cornerRadius: 26).fill(Color(uiColor: .secondarySystemGroupedBackground))
                    if let image {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityLabel("Photo taken \(asset.creationDate?.formatted(date: .abbreviated, time: .omitted) ?? "on an unknown date")")
                    } else if let failure {
                        VStack(spacing: 12) {
                            Image(systemName: "icloud.slash").font(.largeTitle)
                            Text(failure).font(.callout).multilineTextAlignment(.center)
                            Button("Retry preview") { library.retryPreview(asset); retry += 1 }
                        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else { Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
                }
                .aspectRatio(CGFloat(max(asset.pixelWidth, 1)) / CGFloat(max(asset.pixelHeight, 1)), contentMode: .fit)
                .overlay(alignment: offset.width < 0 ? .topTrailing : .topLeading) {
                    Text(offset.width < 0 ? "BIN" : "KEEP")
                        .font(.title.bold()).foregroundStyle(offset.width < 0 ? Color.red : Color.green)
                        .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .rotationEffect(.degrees(offset.width < 0 ? 12 : -12)).padding(24)
                        .opacity(min(abs(offset.width) / 85, 1))
                        .accessibilityIdentifier(offset.width < 0 ? "swipe-bin-overlay" : "swipe-keep-overlay")
                }
                .clipShape(RoundedRectangle(cornerRadius: 26))
                .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
                .offset(offset).rotationEffect(.degrees(reduceMotion ? 0 : Double(offset.width / 22)))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 12)
                    .onChanged { value in if !committing { offset = value.translation } }
                    .onEnded { value in
                        guard !committing else { return }
                        if abs(value.translation.width) > 100 { commit(value.translation.width > 0 ? .keep : .bin) }
                        else { withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) { offset = .zero } }
                    })
                .accessibilityAction(named: "Keep photo") { commit(.keep) }
                .accessibilityAction(named: "Move to Bin") { commit(.bin) }
                .zIndex(1)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .zIndex(1)
                .accessibilityIdentifier("photo-stack")
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(asset.creationDate?.formatted(date: .abbreviated, time: .omitted) ?? "Unknown date").font(.subheadline.weight(.semibold))
                    Text("\(asset.pixelWidth) × \(asset.pixelHeight) · \(String(format: "%.1f", Double(asset.pixelWidth) * Double(asset.pixelHeight) / 1_000_000)) MP").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: info) { Image(systemName: "info") }
                    .buttonStyle(PhotoActionStyle(compact: true)).buttonBorderShape(.circle).accessibilityLabel("Photo information").accessibilityIdentifier("photo-info")
                    .disabled(committing)
            }
            HStack {
                Text(fileSize).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if fileSize.hasPrefix("Original size unavailable") {
                    Button("Retry download") { library.retryOriginalDownload(asset); sizeRetry += 1 }
                        .font(.caption)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button(action: fullscreen) { Label("Preview", systemImage: "arrow.up.left.and.arrow.down.right").frame(maxWidth: .infinity) }
                    .buttonStyle(PhotoActionStyle()).accessibilityLabel("Preview full screen").accessibilityIdentifier("preview-fullscreen")
                Button(action: compress) { Label("Compress", systemImage: "arrow.down.right.and.arrow.up.left").frame(maxWidth: .infinity) }
                    .buttonStyle(PhotoActionStyle(color: .purple))
            }.controlSize(.regular).disabled(committing)
            HStack(spacing: 14) {
                Button { commit(.bin) } label: { Label("Bin", systemImage: "trash").frame(maxWidth: .infinity).padding(.vertical, 10) }
                    .buttonStyle(PhotoActionStyle(color: .red)).accessibilityIdentifier("review-bin")
                Button { commit(.keep) } label: { Label("Keep", systemImage: "heart").frame(maxWidth: .infinity).padding(.vertical, 10) }
                    .buttonStyle(PhotoActionStyle(color: .green))
            }.disabled(committing)
        }
        .task(id: "\(asset.localIdentifier)-\(library.revision)-\(sizeRetry)") {
            fileSize = "Downloading original size…"
            let size = await library.originalSize(asset)
            if !Task.isCancelled { fileSize = size }
        }
        .onDisappear { advance?.cancel() }
        .task(id: "\(library.revision)-\(retry)") {
            failure = nil
            do { image = try await library.preview(asset, size: targetSize) }
            catch is CancellationError { }
            catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }
    private func commit(_ choice: ReviewChoice) {
        guard !committing else { return }
        committing = true
        withAnimation(reduceMotion ? nil : .easeIn(duration: 0.22), completionCriteria: .logicallyComplete) {
            offset = CGSize(width: choice == .keep ? 600 : -600, height: 30)
        } completion: {
            advance = Task {
                await decide(choice)
                // If persistence failed the card is still present and can be retried.
                offset = .zero; committing = false
            }
        }
    }
}

private struct StackedPhoto: View {
    let asset: PHAsset
    let library: PhotoLibraryService
    let targetSize: CGSize
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26).fill(Color(uiColor: .secondarySystemBackground))
            if let preview = image ?? library.cachedPreview(asset) {
                Image(uiImage: preview).resizable().scaledToFit()
            }
        }
        .aspectRatio(CGFloat(max(asset.pixelWidth, 1)) / CGFloat(max(asset.pixelHeight, 1)), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
        .task(id: "\(asset.localIdentifier)-\(library.revision)") {
            image = try? await library.preview(asset, size: targetSize)
        }
    }
}

struct PhotoThumbnail: View {
    let asset: PHAsset
    let library: PhotoLibraryService
    @State private var image: UIImage?
    @Environment(\.displayScale) private var scale
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color(uiColor: .systemBackground))
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }.frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityHidden(true)
            .task(id: library.revision) {
                image = nil
                do { image = try await library.preview(asset, size: CGSize(width: 64 * scale, height: 64 * scale)) }
                catch { }
            }
    }
}

struct BinView: View {
    @Bindable var model: AppModel
    @State private var selected: Set<String> = []
    @State private var confirming = false
    @State private var confirmationIDs: Set<String> = []
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(model.store.binIDs.count) in Bin").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button(selected.count == model.binAssets.count && !selected.isEmpty ? "Deselect all" : "Select all") {
                    selected = selected.count == model.binAssets.count ? [] : Set(model.binAssets.map(\.id))
                }.buttonStyle(PhotoActionStyle()).disabled(model.binAssets.isEmpty)
            }.padding(.horizontal, 20).padding(.vertical, 8)

        List {
            Section {
                Text("Photos here are still in your library. Restore them anytime. Deleting from Photos requires your confirmation below and iOS approval.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if model.unavailableBinCount > 0 {
                Section("\(model.unavailableBinCount) unavailable") {
                    Text("Some Bin photos were removed or are outside your selected Photos access. Their decisions are saved. Broaden access to restore them, or dismiss their local Bin entries.")
                        .font(.footnote)
                    if model.library.authorization == .limited { LimitedLibraryButton { Task { await model.library.refresh() } } }
                    Button("Dismiss unavailable Bin entries") {
                        let missing = Set(model.store.binIDs).subtracting(model.binAssets.map(\.localIdentifier))
                        model.restore(missing)
                    }.disabled(model.deleting || model.updatingReview)
                }
            }
            Section("\(model.binAssets.count) photos available") {
                if model.binAssets.isEmpty { Text("Your Bin is empty. Photos you swipe left will appear here.").foregroundStyle(.secondary) }
                ForEach(model.binAssets) { asset in
                    HStack(spacing: 12) {
                        Button {
                            if selected.contains(asset.id) { selected.remove(asset.id) } else { selected.insert(asset.id) }
                        } label: {
                            Image(systemName: selected.contains(asset.id) ? "checkmark.circle.fill" : "circle").font(.title2)
                        }.buttonStyle(PhotoActionStyle(color: selected.contains(asset.id) ? .blue : nil, compact: true)).buttonBorderShape(.circle)
                            .accessibilityLabel("\(selected.contains(asset.id) ? "Deselect" : "Select") photo from \(asset.creationDate?.formatted(date: .abbreviated, time: .omitted) ?? "unknown date")")
                        PhotoThumbnail(asset: asset, library: model.library)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(asset.creationDate?.formatted(date: .abbreviated, time: .omitted) ?? "Unknown date")
                            Text("\(asset.pixelWidth) × \(asset.pixelHeight) · \(String(format: "%.1f", Double(asset.pixelWidth) * Double(asset.pixelHeight) / 1_000_000)) MP").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            Button("Restore", systemImage: "arrow.uturn.backward") { model.restore([asset.id]); selected.remove(asset.id) }
                            Button("Photo information", systemImage: "info.circle") { model.photoSheet = .info(asset) }
                            Button("Compress", systemImage: "arrow.down.right.and.arrow.up.left") { model.photoSheet = .compression(asset) }
                        } label: { Image(systemName: "ellipsis").font(.title3) }
                            .buttonStyle(PhotoActionStyle(compact: true)).buttonBorderShape(.circle)
                            .accessibilityLabel("Photo actions")
                    }
                    .swipeActions(edge: .leading) { Button("Restore") { model.restore([asset.id]); selected.remove(asset.id) }.tint(Color.green) }
                }
            }
            Section {
                Text("Swipix's Bin is separate from Apple's Recently Deleted album. After confirmed deletion, iOS may retain photos there according to its system policy. Storage may not be freed immediately.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
            .listStyle(.insetGrouped)
            HStack {
                Button("Restore \(selected.count)") { model.restore(selected); selected = [] }.buttonStyle(PhotoActionStyle(color: .blue))
                Spacer()
                if model.deleting { ProgressView("Deleting…") }
                else {
                    Button("Delete \(selected.count) from Photos", role: .destructive) {
                        confirmationIDs = selected; confirming = true
                    }.buttonStyle(PhotoActionStyle(color: .red))
                }
            }.fixedSize(horizontal: false, vertical: true).padding().background(.regularMaterial).disabled(selected.isEmpty || model.deleting || model.updatingReview)
        }

        .alert("Delete \(confirmationIDs.count) photos from your Photos library?", isPresented: $confirming) {
            Button("Delete from Photos", role: .destructive) {
                let ids = confirmationIDs
                Task { await model.delete(ids); selected.formIntersection(model.binAssets.map(\.id)) }
            }
            Button("Cancel", role: .cancel) { }
        } message: { Text("This requests deletion from Photos, including iCloud Photos on synced devices. iOS may keep the photos in Recently Deleted. Swipix cannot permanently erase that album.") }


        .onChange(of: model.library.revision) { _, _ in selected.formIntersection(model.binAssets.map(\.id)) }

    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @AppStorage("compressionPreset") private var preset: CompressionPreset = .medium
    @AppStorage("compressionFormat") private var format: CompressionFormat = CompressionFormat.preferred
    var body: some View {
        Form {
            Section("Compression defaults") {
                Picker("Preset", selection: $preset) { ForEach(CompressionPreset.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                Text(preset.detail).font(.subheadline)
                Picker("Format", selection: $format) {
                    Text("JPEG").tag(CompressionFormat.jpeg)
                    if CompressionFormat.supportsHEIC { Text("HEIC").tag(CompressionFormat.heic) }
                }.pickerStyle(.segmented)
                Text("Your last used preset and format are remembered. Medium is the initial preset.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Photos access") {
                Text(model.library.authorization == .limited ? "Limited access — selected photos only" : "Full library access")
                if model.library.authorization == .limited { LimitedLibraryButton { Task { await model.library.refresh() } } }
                Button("Open Settings") { openSettings() }.buttonStyle(PhotoActionStyle(color: .blue))
            }
            Section("Safe by design") {
                Label("Swipes save decisions, never delete", systemImage: "checkmark.shield")
                Label("Compression keeps the result and bins the original", systemImage: "square.on.square")
                Text("No uploads, analytics or remote processing. Photos automatically downloads the current photo and next five from iCloud for previews and original sizes.")
                Text("Bin deletion requests go through PhotoKit and the iOS confirmation flow. Swipix cannot bypass Recently Deleted.")
            }
            Section("Compression support") {
                Text("JPEG and HEIC/HEIF originals can be encoded as JPEG or HEIC. High and Medium keep full resolution. Low reduces width and height to two-thirds. RAW, ProRAW, animated files and other formats remain unchanged.")
                Text("Compression reads the original resource. Photos edits are not applied. Metadata is copied and compared before saving; unavailable or proprietary metadata is never guaranteed.")
            }
        }
    }
}

@MainActor private func openSettings() {
    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
}

/// Present with a controller in this scene, including when inside a sheet.
struct LimitedLibraryButton: View {
    let completion: () -> Void
    @State private var presenting = false
    var body: some View {
        Button("Choose more photos") { presenting = true }
            .buttonStyle(PhotoActionStyle(color: .blue))
            .background(LimitedLibraryPresenter(presenting: $presenting, completion: completion).frame(width: 0, height: 0))
    }
}
private struct LimitedLibraryPresenter: UIViewControllerRepresentable {
    @Binding var presenting: Bool
    let completion: () -> Void
    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }
    func updateUIViewController(_ controller: UIViewController, context: Context) {
        guard presenting, controller.viewIfLoaded?.window != nil, controller.presentedViewController == nil else { return }
        DispatchQueue.main.async {
            presenting = false
            PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller) { _ in Task { @MainActor in completion() } }
        }
    }
}

/// Use the system's Liquid Glass buttons, with a visible surface and native interaction.
struct PhotoActionStyle: PrimitiveButtonStyle {
    var color: Color? = nil
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        let button = Button(role: configuration.role, action: configuration.trigger) {
            configuration.label.frame(minWidth: compact ? 24 : 44, minHeight: compact ? 24 : 44)
        }
        if let color {
            button.buttonStyle(.glassProminent).tint(color)
        } else {
            button.buttonStyle(.glass).tint(.gray)
        }
    }
}
