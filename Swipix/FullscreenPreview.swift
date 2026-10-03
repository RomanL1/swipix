import SwiftUI
import Photos
import PhotosUI

struct FullscreenPreview: View {
    let asset: PHAsset
    let library: PhotoLibraryService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var scale
    @State private var image: UIImage?
    @State private var livePhoto: PHLivePhoto?
    @State private var playing = false
    @State private var showingInfo = false
    @State private var failure: String?
    var body: some View {
        GeometryReader { geometry in
            NavigationStack {
                ZStack {
                    Color.black.ignoresSafeArea()
                    if playing, let livePhoto { LivePhotoPlayer(photo: livePhoto) }
                    else if let image { ZoomablePhoto(image: image) }
                    if let failure { Text(failure).foregroundStyle(.white).padding().background(.black.opacity(0.7)) }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showingInfo = true } label: { Image(systemName: "info") }
                            .buttonBorderShape(.circle).accessibilityLabel("Photo information")
                    }
                    if asset.mediaSubtypes.contains(.photoLive) {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(playing ? "Show still" : "Play Live Photo") { playing.toggle() }
                                .disabled(livePhoto == nil)
                        }
                    }
                }
                .sheet(isPresented: $showingInfo) { PhotoInfoView(asset: asset, library: library) }
                .buttonStyle(.bordered)
                .toolbarBackground(.black, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
                .tint(.white).preferredColorScheme(.dark)
                .task {
                    image = library.cachedPreview(asset)
                    let factor = min(scale, 3200 / max(geometry.size.width, geometry.size.height))
                    let size = CGSize(width: geometry.size.width * factor, height: geometry.size.height * factor)
                    do { image = try await library.preview(asset, size: size) }
                    catch is CancellationError { }
                    catch { if image == nil { failure = error.localizedDescription } }
                }
                .task {
                    guard asset.mediaSubtypes.contains(.photoLive) else { return }
                    do { livePhoto = try await library.livePreview(asset) }
                    catch is CancellationError { }
                    catch { failure = "Live Photo playback unavailable: \(error.localizedDescription)" }
                }
            }
        }
    }
}

private struct ZoomablePhoto: UIViewRepresentable {
    let image: UIImage
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = PhotoScrollView()
        scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 5
        scroll.delegate = context.coordinator
        scroll.showsHorizontalScrollIndicator = false; scroll.showsVerticalScrollIndicator = false
        let view = context.coordinator.imageView
        view.contentMode = .scaleAspectFit; view.isAccessibilityElement = true
        view.accessibilityLabel = "Full screen photo"
        view.accessibilityHint = "Pinch to zoom. Double tap to zoom in or reset."
        scroll.photoView = view; scroll.addSubview(view)
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2; scroll.addGestureRecognizer(doubleTap)
        return scroll
    }
    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.imageView.image = image
        if scroll.zoomScale == 1 { context.coordinator.imageView.frame = scroll.bounds }
    }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        func scrollViewDidZoom(_ scroll: UIScrollView) {
            imageView.center = CGPoint(x: max(scroll.bounds.width, scroll.contentSize.width) / 2,
                                       y: max(scroll.bounds.height, scroll.contentSize.height) / 2)
        }
        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView else { return }
            if scroll.zoomScale > 1 { scroll.setZoomScale(1, animated: true) }
            else {
                let point = gesture.location(in: imageView)
                let size = CGSize(width: scroll.bounds.width / 3, height: scroll.bounds.height / 3)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
            }
        }
    }
}

private struct LivePhotoPlayer: UIViewRepresentable {
    let photo: PHLivePhoto
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = PhotoScrollView()
        scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 5
        scroll.showsHorizontalScrollIndicator = false; scroll.showsVerticalScrollIndicator = false
        scroll.delegate = context.coordinator
        let view = context.coordinator.liveView
        view.contentMode = .scaleAspectFit; view.livePhoto = photo
        scroll.photoView = view; scroll.addSubview(view)
        return scroll
    }
    func updateUIView(_ scroll: UIScrollView, context: Context) {
        let view = context.coordinator.liveView
        if view.livePhoto !== photo { view.livePhoto = photo; if view.window != nil { view.startPlayback(with: .full) } }
    }
    static func dismantleUIView(_ scroll: UIScrollView, coordinator: Coordinator) { coordinator.liveView.stopPlayback() }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        let liveView = LivePlaybackView()
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { liveView }
        func scrollViewDidZoom(_ scroll: UIScrollView) {
            liveView.center = CGPoint(x: max(scroll.bounds.width, scroll.contentSize.width) / 2,
                                      y: max(scroll.bounds.height, scroll.contentSize.height) / 2)
        }
    }
}

private final class LivePlaybackView: PHLivePhotoView {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { startPlayback(with: .full) } else { stopPlayback() }
    }
}

private final class PhotoScrollView: UIScrollView {
    var photoView: UIView?
    private var previousSize = CGSize.zero
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != previousSize && bounds.width > 0 && bounds.height > 0 {
            previousSize = bounds.size
            setZoomScale(1, animated: false)
            photoView?.frame = CGRect(origin: .zero, size: bounds.size)
            contentSize = bounds.size
        }
    }
}
