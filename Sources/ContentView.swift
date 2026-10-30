import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class UpscaleModel {
    enum State: Equatable {
        case idle
        case running
        case finished(URL)
        case failed(String)
    }

    var input: URL?
    var inputDescription = ""
    var state = State.idle
    var progress = 0.0
    var status = ""

    private var upscaler: Upscaler?
    private var task: Task<Void, Never>?

    var isRunning: Bool { state == .running }

    func select(_ url: URL) {
        guard !isRunning else { return }
        input = url
        state = .idle
        progress = 0
        status = ""
        inputDescription = ""
        Task {
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let size = try? await track.load(.naturalSize) else {
                if input == url { inputDescription = "No video track found" }
                return
            }
            let w = Int(size.width.rounded()), h = Int(size.height.rounded())
            let s = Upscaler.scaleFactor
            if input == url { inputDescription = "\(w) × \(h)  →  \(w * s) × \(h * s)" }
        }
    }

    func go() {
        guard let input, !isRunning else { return }
        let output = Upscaler.outputURL(for: input)
        let upscaler = Upscaler()
        self.upscaler = upscaler
        state = .running
        progress = 0
        status = "Preparing…"

        task = Task {
            do {
                try await upscaler.run(input: input, output: output) { phase in
                    Task { @MainActor in self.update(phase) }
                }
                progress = 1
                status = "Saved as “\(output.lastPathComponent)”"
                state = .finished(output)
            } catch is CancellationError {
                progress = 0
                status = "Cancelled"
                state = .idle
            } catch {
                status = error.localizedDescription
                state = .failed(error.localizedDescription)
            }
            self.upscaler = nil
        }
    }

    func cancel() {
        upscaler?.cancel()
        task?.cancel()
    }

    private func update(_ phase: Upscaler.Phase) {
        guard isRunning else { return }
        switch phase {
        case let .downloadingModel(fraction):
            progress = fraction
            status = "Downloading Super Resolution model… \(Int(fraction * 100))%"
        case let .upscaling(fraction):
            progress = fraction
            status = "Upscaling… \(Int(fraction * 100))%"
        }
    }
}

struct ContentView: View {
    @State private var model = UpscaleModel()
    @State private var choosingFile = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 20) {
            dropZone
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                HStack(spacing: 6) {
                    if case .failed = model.state {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    } else if case .finished = model.state {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    Text(model.status.isEmpty ? " " : model.status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    if case let .finished(url) = model.state {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                        .buttonStyle(.link)
                        .font(.callout)
                    }
                }
            }
            HStack {
                Spacer()
                if model.isRunning {
                    Button("Cancel", role: .cancel) { model.cancel() }
                        .controlSize(.large)
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Go") { model.go() }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.input == nil || !Upscaler.isSupported)
                        .frame(minWidth: 90)
                }
            }
        }
        .padding(24)
        .frame(width: 500)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.movie]) { result in
            if case let .success(url) = result { model.select(url) }
        }
        .onAppear {
            if !Upscaler.isSupported {
                model.status = "Super Resolution isn’t supported on this Mac."
                model.state = .failed(model.status)
            }
        }
    }

    private var dropZone: some View {
        Button { choosingFile = true } label: {
            VStack(spacing: 10) {
                Image(systemName: model.input == nil ? "film.stack" : "film")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
                if let input = model.input {
                    Text(input.lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(model.inputDescription.isEmpty ? " " : model.inputDescription)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("Drop a video here")
                        .font(.headline)
                    Text("or click to choose a file · up to 1920 × 1080")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 170)
            .contentShape(.rect)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(dropTargeted ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.quaternary.opacity(0.5)))
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        dropTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(model.isRunning)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .movie) ?? false })
            else { return false }
            model.select(url)
            return true
        } isTargeted: { dropTargeted = $0 }
    }
}
