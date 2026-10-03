import SwiftUI
import Photos
import ImageIO
import Observation

@MainActor @Observable final class CompressionModel {
    var result: CompressionResult?
    var preview: UIImage?
    var error: String?
    var processing = false
    var saving = false
    var saved = false
    private var operation: Task<Void, Never>?
    private var closeRequested = false
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Swipix-\(UUID().uuidString)", isDirectory: true)

    func start(app: AppModel, asset: PHAsset, quality: Double) {
        guard !processing, !saving else { return }
        result = nil; preview = nil; error = nil; saved = false; processing = true
        operation = Task {
            defer { processing = false; operation = nil }
            do {
                try? FileManager.default.removeItem(at: directory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let source = directory.appendingPathComponent("original")
                _ = try await app.library.exportOriginal(asset, to: source)
                let encoded = try await app.compressor.compress(sourceURL: source, outputDirectory: directory,
                    configuration: CompressionConfiguration(quality: quality))
                try Task.checkCancellation()
                // The compressed review preview is bounded too; never decode it at full resolution for UI.
                if let imageSource = CGImageSourceCreateWithURL(encoded.outputURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                   let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1200
                   ] as CFDictionary) { preview = UIImage(cgImage: thumbnail) }
                result = encoded
                try? FileManager.default.removeItem(at: source)
            } catch {
                cleanup()
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }
    func save(app: AppModel, asset: PHAsset) async {
        guard let result, !processing, !saving, !saved else { return }
        saving = true; defer { saving = false; if closeRequested { cleanup() } }
        do { try await app.library.saveCopy(result, from: asset); saved = true }
        catch { self.error = error.localizedDescription }
    }
    func invalidateQuality() {
        guard !processing, !saving, !saved else { return }
        result = nil; preview = nil; cleanup()
    }
    func close() {
        closeRequested = true
        if saving { return }
        if let operation { operation.cancel() } else { cleanup() }
    }
    private func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

struct CompressionView: View {
    let model: AppModel
    let asset: PHAsset
    @State private var workflow = CompressionModel()
    @AppStorage("compressionQuality") private var quality = 0.8
    @State private var confirming = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Save a smaller copy. Your original stays in Photos.").font(.headline)
                    Text("This uses the original file, including its original metadata. Photos edits are not applied. Live Photos produce a still-image copy.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Quality") {
                    Slider(value: $quality, in: 0.35...0.95, step: 0.05).disabled(workflow.processing || workflow.saving || workflow.saved)
                        .onChange(of: quality) { _, _ in workflow.invalidateQuality() }
                    Text("\(quality, format: .percent.precision(.fractionLength(0))) · Original pixel dimensions")
                    Button(workflow.result == nil ? "Prepare compressed copy" : "Rebuild with this quality") {
                        workflow.start(app: model, asset: asset, quality: quality)
                    }.disabled(workflow.processing || workflow.saving || workflow.saved)
                    if workflow.processing { ProgressView("Downloading original and verifying copy…") }
                }
                if let error = workflow.error {
                    Section("Could not finish") { Text(error).foregroundStyle(.red) }
                }
                if let result = workflow.result {
                    Section("Copy review") {
                        if let preview = workflow.preview {
                            Image(uiImage: preview).resizable().scaledToFit().frame(maxHeight: 280)
                                .accessibilityLabel("Compressed copy preview")
                        }
                        LabeledContent("Original", value: bytes(result.originalBytes))
                        LabeledContent("Compressed copy", value: bytes(result.compressedBytes))
                        LabeledContent("Reduction", value: result.savings > 0 ? bytes(result.savings) : "No reduction")
                        LabeledContent("Dimensions", value: "\(result.width) × \(result.height)")
                        LabeledContent("Format", value: "\(result.originalFormat) → \(result.outputFormat)")
                        if result.savings <= 0 {
                            Text("This copy is not smaller. Try a lower quality. It cannot be saved as a compressed copy at this setting.").font(.footnote)
                        }
                    }
                    Section("Metadata verification") {
                        Text(result.metadata.summary).font(.subheadline.weight(.semibold))
                        if !result.metadata.differences.isEmpty {
                            DisclosureGroup("Changed or missing fields") {
                                ForEach(result.metadata.differences, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                            }
                        }
                        ForEach(result.metadata.limitations, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
                    }
                    Section {
                        if workflow.saved {
                            Label("Copy saved. Original retained.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button { confirming = true } label: {
                                if workflow.saving { ProgressView("Saving copy…") } else { Text("Save compressed copy to Photos") }
                            }.buttonStyle(.borderedProminent).disabled(workflow.saving || workflow.processing || result.savings <= 0)
                        }
                    }
                }
            }
            .navigationTitle("Compress a copy").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(workflow.processing ? "Cancel" : "Done") { workflow.close(); dismiss() }.disabled(workflow.saving)
                }
            }
            .confirmationDialog("Save this compressed copy to Photos?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Save copy — keep original") { Task { await workflow.save(app: model, asset: asset) } }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("The original will remain in your library. \(workflow.result?.metadata.summary ?? "") Review the metadata limitations above; Photos may normalize imported metadata.")
            }
            .interactiveDismissDisabled(workflow.processing || workflow.saving)
        }.buttonStyle(.bordered).onDisappear { workflow.close() }
    }
}

private func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
