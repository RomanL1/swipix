import SwiftUI
import Photos
import Observation

@MainActor @Observable final class CompressionModel {
    var result: CompressionResult?
    var error: String?
    var processing = false
    var saving = false
    var saved = false
    private(set) var createdID: String?
    private var operation: Task<Void, Never>?
    private var closeRequested = false
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Swipix-\(UUID().uuidString)", isDirectory: true)
    var busy: Bool { processing || saving }

    func start(app: AppModel, asset: PHAsset, preset: CompressionPreset, format: CompressionFormat) {
        guard !busy, createdID == nil else { return }
        result = nil; error = nil; saved = false; processing = true
        operation = Task {
            defer {
                processing = false; saving = false; operation = nil
                if saved || closeRequested || createdID == nil { cleanup() }
            }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let source = directory.appendingPathComponent("original")
                _ = try await app.library.exportOriginal(asset, to: source)
                let encoded = try await app.compressor.compress(sourceURL: source, outputDirectory: directory,
                    configuration: CompressionConfiguration(preset: preset, format: format))
                result = encoded
                try Task.checkCancellation()
                guard encoded.savings > 0 else {
                    throw PhotoFailure(message: "This preset did not make a smaller file. Nothing was saved or moved to the Bin. Try another preset or format.")
                }
                saving = true
                let id = try await app.library.saveCopy(encoded, from: asset)
                createdID = id
                do { try await app.finishCompression(original: asset, compressedID: id, result: encoded) }
                catch { throw PhotoFailure(message: "The compressed photo was saved, but the original could not be moved to the Bin. Both photos remain in Photos. Retry the Bin step below without creating another copy. \(error.localizedDescription)") }
                saved = true
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
    func retryBin(app: AppModel, asset: PHAsset) {
        guard !busy, let createdID, let result else { return }
        saving = true
        operation = Task {
            defer { saving = false; operation = nil }
            do { try await app.finishCompression(original: asset, compressedID: createdID, result: result); saved = true; cleanup() }
            catch { self.error = error.localizedDescription }
        }
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
    @AppStorage("compressionPreset") private var preset: CompressionPreset = .medium
    @AppStorage("compressionFormat") private var format: CompressionFormat = CompressionFormat.preferred
    @AppStorage("livePhotoCompressionWarningAcknowledged") private var acknowledgedLiveWarning = false
    @State private var showingFirstWarning = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Keep the compressed photo. Move the original into your Bin.").font(.headline)
                    Text("Choose a preset to compress and save immediately. The original can be restored from the Bin. Space is freed only after you delete originals from the Bin.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Picker("Output format", selection: $format) {
                        Text("JPEG").tag(CompressionFormat.jpeg)
                        if CompressionFormat.supportsHEIC { Text("HEIC").tag(CompressionFormat.heic) }
                    }.pickerStyle(.segmented).disabled(workflow.busy || workflow.createdID != nil)
                    ForEach(CompressionPreset.allCases) { option in
                        Button {
                            preset = option
                            workflow.start(app: model, asset: asset, preset: option, format: format)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(option.title).font(.headline)
                                    Text(option.detail).font(.subheadline)
                                }
                                Spacer()
                                Image(systemName: preset == option ? "checkmark.circle.fill" : "arrow.right.circle")
                                    .font(.title2)
                            }.frame(maxWidth: .infinity).padding(.vertical, 8)
                        }.buttonStyle(PhotoActionStyle(color: .blue)).buttonBorderShape(.roundedRectangle(radius: 20))
                            .accessibilityIdentifier("compress-\(option.rawValue)")
                            .accessibilityValue(preset == option ? "Last used" : "")
                            .disabled(workflow.busy || showingFirstWarning || workflow.createdID != nil)
                    }
                    if workflow.busy { ProgressView(workflow.saving ? "Saving photo and moving original to Bin…" : "Downloading original, compressing and verifying…") }
                    CompressionWarning {
                        Text(asset.mediaSubtypes.contains(.photoLive)
                             ? "Live Photo motion and audio are not included in the compressed photo. The original Live Photo stays in your Bin; deleting it later removes that motion and audio."
                             : "Compressed versions of Live Photos lose motion and audio. The original is retained in the Bin until you delete it.")
                    }
                    CompressionWarning {
                        Text("Metadata is copied and checked, but some fields and image features may not survive. Low also discards depth, portrait mattes and HDR gain maps. Photos edits are not applied. The result report lists detected changes.")
                    }
                    if let error = workflow.error {
                        Text(error).font(.callout).foregroundStyle(.red)
                        if workflow.createdID != nil {
                            Button("Finish moving original to Bin") { workflow.retryBin(app: model, asset: asset) }
                                .buttonStyle(PhotoActionStyle(color: .blue)).disabled(workflow.busy)
                        }
                        if let result = workflow.result { CompressionResultDetails(result: result) }
                    }
                }.padding(20)
            }
            .navigationTitle("Compress photo").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { workflow.close(); dismiss() } label: {
                        Image(systemName: "xmark")
                    }.buttonStyle(PhotoActionStyle(compact: true)).buttonBorderShape(.circle)
                        .accessibilityLabel(workflow.processing ? "Cancel" : "Done")
                        .disabled(workflow.saving)
                }.sharedBackgroundVisibility(.hidden)
            }
            .buttonStyle(PhotoActionStyle())
            .alert("Live Photo compression warning", isPresented: $showingFirstWarning) {
                Button("OK") { acknowledgedLiveWarning = true }
            } message: {
                Text("Compressing a Live Photo creates a still photo without motion or audio. Its original stays in your Bin, so you can restore it. Deleting that original from the Bin removes its Live Photo data. This warning appears once; the yellow warning remains in the compression popup.")
            }
            .onAppear {
                if format == .original || (format == .heic && !CompressionFormat.supportsHEIC) { format = .preferred }
                showingFirstWarning = !acknowledgedLiveWarning
            }
            .onChange(of: workflow.saved) { _, saved in if saved { dismiss() } }
            .interactiveDismissDisabled(workflow.saving)
        }.presentationDetents([.large]).presentationDragIndicator(.visible)
            .onDisappear { workflow.close() }
    }
}

private struct CompressionWarning<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow).font(.title3)
            content().font(.footnote)
        }.padding().frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct CompressionReportView: View {
    let result: CompressionResult
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section { Label("Compressed photo kept. Original in Bin.", systemImage: "checkmark.circle") }
                CompressionResultDetails(result: result)
            }.navigationTitle("Compression details").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(PhotoActionStyle(compact: true)).buttonBorderShape(.circle).accessibilityLabel("Done") }.sharedBackgroundVisibility(.hidden) }
                .buttonStyle(PhotoActionStyle())
        }
    }
}

private struct CompressionResultDetails: View {
    let result: CompressionResult
    @State private var showingDifferences = false
    var body: some View {
        Section("File sizes") {
            LabeledContent("Original", value: bytes(result.originalBytes))
            LabeledContent("Compressed", value: bytes(result.compressedBytes))
            LabeledContent("Reduction", value: result.savings > 0 ? bytes(result.savings) : "No reduction")
            LabeledContent("Dimensions", value: "\(result.width) × \(result.height)")
            LabeledContent("Format", value: "\(formatName(result.originalFormat)) → \(formatName(result.outputFormat))")
        }
        Section("Metadata verification") {
            Label(result.metadata.summary, systemImage: "exclamationmark.triangle.fill")
            ForEach(result.metadata.intentionalChanges, id: \.self) { Text($0).font(.footnote) }
            if !result.metadata.differences.isEmpty {
                Button { showingDifferences.toggle() } label: {
                    Label("Changed or missing fields", systemImage: showingDifferences ? "chevron.up" : "chevron.down")
                }.accessibilityValue(showingDifferences ? "Expanded" : "Collapsed")
                if showingDifferences {
                    ForEach(result.metadata.differences, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                }
            }
            ForEach(result.metadata.limitations, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
        }
    }
}

private func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }

private func formatName(_ identifier: String) -> String {
    switch identifier { case "public.jpeg": "JPEG"; case "public.heic", "public.heif": "HEIC / HEIF"; default: identifier }
}
