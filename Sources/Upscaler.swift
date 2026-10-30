import AVFoundation
import CoreVideo
import Synchronization
import VideoToolbox

/// Upscales a video file with Apple's VideoToolbox Super Resolution scaler.
///
/// Pipeline: AVAssetReader (10-bit YUV) → pixel transfer to RGBA half float → VTFrameProcessor
/// super resolution → pixel transfer back to 10-bit YUV → AVAssetWriter (HEVC Main10).
/// Audio is passed through untouched when the container allows it, otherwise re-encoded to AAC.
/// Everything is written straight into the destination file; no temporary files are created.
final class Upscaler: @unchecked Sendable {
    enum Phase: Sendable {
        case downloadingModel(Double)
        case upscaling(Double)
    }

    enum UpscaleError: LocalizedError {
        case notSupported
        case noVideoTrack
        case tooLarge(width: Int, height: Int)
        case cannotRead(String)
        case cannotWrite(String)
        case processing(String)

        var errorDescription: String? {
            switch self {
            case .notSupported:
                "Super Resolution isn’t supported on this Mac."
            case .noVideoTrack:
                "The file has no video track."
            case let .tooLarge(width, height):
                "The video is \(width)×\(height). Super Resolution accepts video up to 1920×1080."
            case let .cannotRead(detail):
                "Couldn’t read the video. \(detail)"
            case let .cannotWrite(detail):
                "Couldn’t write the upscaled video. \(detail)"
            case let .processing(detail):
                "Upscaling failed. \(detail)"
            }
        }
    }

    private let lock = NSLock()
    private var reader: AVAssetReader?
    private var writer: AVAssetWriter?
    private var cancelled = false

    static var isSupported: Bool { VTSuperResolutionScalerConfiguration.isSupported }

    static var scaleFactor: Int {
        VTSuperResolutionScalerConfiguration.supportedScaleFactors.max() ?? 4
    }

    /// Returns "<name> upscaled.<ext>" next to the source, adding a number if that file already exists.
    static func outputURL(for input: URL) -> URL {
        let folder = input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent + " upscaled"
        let ext = fileType(for: input).ext
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    private static func fileType(for input: URL) -> (type: AVFileType, ext: String) {
        switch input.pathExtension.lowercased() {
        case "mp4": (.mp4, "mp4")
        case "m4v": (.m4v, "m4v")
        default: (.mov, "mov")
        }
    }

    func cancel() {
        let reader = lock.withLock {
            cancelled = true
            return self.reader
        }
        reader?.cancelReading()
    }

    private var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func run(input: URL, output: URL, progress: @escaping @Sendable (Phase) -> Void) async throws {
        guard Self.isSupported else { throw UpscaleError.notSupported }

        let asset = AVURLAsset(url: input)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw UpscaleError.noVideoTrack
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration)
        let (naturalSize, transform, nominalFPS, formats) = try await videoTrack.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions)

        let width = Int(naturalSize.width.rounded())
        let height = Int(naturalSize.height.rounded())
        let scale = Self.scaleFactor
        guard let configuration = VTSuperResolutionScalerConfiguration(
            frameWidth: width,
            frameHeight: height,
            scaleFactor: scale,
            inputType: .video,
            usePrecomputedFlow: false,
            qualityPrioritization: .normal,
            revision: VTSuperResolutionScalerConfiguration.defaultRevision
        ) else {
            throw UpscaleError.tooLarge(width: width, height: height)
        }

        try await ensureModel(configuration, progress: progress)
        try Task.checkCancellation()
        progress(.upscaling(0))

        let outWidth = width * scale
        let outHeight = height * scale
        let colorProperties = Self.colorProperties(from: formats.first)

        // MARK: Reader

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch {
            throw UpscaleError.cannotRead(error.localizedDescription)
        }
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        // MARK: Writer

        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: output, fileType: Self.fileType(for: input).type) } catch {
            throw UpscaleError.cannotWrite(error.localizedDescription)
        }
        let fps = Double(nominalFPS > 0 ? nominalFPS : 30)
        let bitRate = Int(Double(outWidth * outHeight) * fps * 0.07)
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: outWidth,
            AVVideoHeightKey: outHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: fps,
            ] as [String: Any],
        ]
        if let colorProperties { videoSettings[AVVideoColorPropertiesKey] = colorProperties }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.transform = transform
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: outWidth,
            kCVPixelBufferHeightKey as String: outHeight,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        guard writer.canAdd(videoInput) else { throw UpscaleError.cannotWrite("The video format isn’t supported.") }
        writer.add(videoInput)

        var audioPairs: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        for track in audioTracks {
            let hint = try await track.load(.formatDescriptions).first
            let passthroughInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
            if writer.canAdd(passthroughInput) {
                let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                guard reader.canAdd(out) else { continue }
                reader.add(out)
                writer.add(passthroughInput)
                audioPairs.append((out, passthroughInput))
            } else {
                let channels = hint.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 2
                let rate = hint.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate } ?? 48_000
                let aacInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVNumberOfChannelsKey: min(Int(channels), 2),
                    AVSampleRateKey: rate,
                    AVEncoderBitRateKey: 256_000,
                ])
                let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVNumberOfChannelsKey: min(Int(channels), 2),
                ])
                guard writer.canAdd(aacInput), reader.canAdd(out) else { continue }
                reader.add(out)
                writer.add(aacInput)
                audioPairs.append((out, aacInput))
            }
        }

        let alreadyCancelled = lock.withLock {
            self.reader = reader
            self.writer = writer
            return cancelled
        }
        if alreadyCancelled { throw CancellationError() }

        guard reader.startReading() else {
            throw UpscaleError.cannotRead(reader.error?.localizedDescription ?? "")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw UpscaleError.cannotWrite(writer.error?.localizedDescription ?? "")
        }
        writer.startSession(atSourceTime: .zero)

        let pairs = audioPairs
        do {
            async let audioDone: Void = Self.copyAudio(pairs)
            try await processVideo(
                configuration: configuration,
                videoOutput: videoOutput,
                videoInput: videoInput,
                adaptor: adaptor,
                width: width, height: height,
                duration: duration,
                progress: progress
            )
            await audioDone
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            if isCancelled { throw CancellationError() }
            throw error
        }

        if isCancelled || reader.status == .cancelled {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw CancellationError()
        }
        if reader.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw UpscaleError.cannotRead(reader.error?.localizedDescription ?? "")
        }

        await writer.finishWriting()
        if writer.status != .completed {
            try? FileManager.default.removeItem(at: output)
            throw UpscaleError.cannotWrite(writer.error?.localizedDescription ?? "")
        }
        progress(.upscaling(1))
    }

    // MARK: - Model

    private func ensureModel(
        _ configuration: VTSuperResolutionScalerConfiguration,
        progress: @escaping @Sendable (Phase) -> Void
    ) async throws {
        guard configuration.configurationModelStatus != .ready else { return }
        progress(.downloadingModel(Double(configuration.configurationModelPercentageAvailable)))

        let failure = Mutex<Error?>(nil)
        if configuration.configurationModelStatus == .downloadRequired {
            configuration.downloadConfigurationModel { error in
                if let error { failure.withLock { $0 = error } }
            }
        }
        while configuration.configurationModelStatus != .ready {
            if isCancelled { throw CancellationError() }
            if let error = failure.withLock({ $0 }) {
                throw UpscaleError.processing("The Super Resolution model couldn’t be downloaded. \(error.localizedDescription)")
            }
            progress(.downloadingModel(Double(configuration.configurationModelPercentageAvailable)))
            try await Task.sleep(for: .milliseconds(250))
        }
        progress(.downloadingModel(1))
    }

    // MARK: - Video

    private func processVideo(
        configuration: VTSuperResolutionScalerConfiguration,
        videoOutput: AVAssetReaderTrackOutput,
        videoInput: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        width: Int, height: Int,
        duration: CMTime,
        progress: @escaping @Sendable (Phase) -> Void
    ) async throws {
        let processor = VTFrameProcessor()
        do { try processor.startSession(configuration: configuration) } catch {
            throw UpscaleError.processing(error.localizedDescription)
        }
        defer { processor.endSession() }

        var transferSession: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transferSession) == noErr,
              let transfer = transferSession else {
            throw UpscaleError.processing("Couldn’t create a pixel transfer session.")
        }
        defer { VTPixelTransferSessionInvalidate(transfer) }

        let sourcePool = try Self.makePool(configuration.sourcePixelBufferAttributes)
        let destinationPool = try Self.makePool(configuration.destinationPixelBufferAttributes)

        var previousSource: VTFrameProcessorFrame?
        var previousOutput: VTFrameProcessorFrame?
        let totalSeconds = max(duration.seconds, 0.001)

        while let sample = videoOutput.copyNextSampleBuffer() {
            if isCancelled { throw CancellationError() }
            guard let decoded = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)

            // YUV → RGBA half float for the scaler.
            let sourceBuffer = try Self.buffer(from: sourcePool)
            CVBufferPropagateAttachments(decoded, sourceBuffer)
            guard VTPixelTransferSessionTransferImage(transfer, from: decoded, to: sourceBuffer) == noErr else {
                throw UpscaleError.processing("Couldn’t convert a frame.")
            }

            let destinationBuffer = try Self.buffer(from: destinationPool)
            guard let sourceFrame = VTFrameProcessorFrame(buffer: sourceBuffer, presentationTimeStamp: pts),
                  let destinationFrame = VTFrameProcessorFrame(buffer: destinationBuffer, presentationTimeStamp: pts),
                  let parameters = VTSuperResolutionScalerParameters(
                      sourceFrame: sourceFrame,
                      previousFrame: previousSource,
                      previousOutputFrame: previousOutput,
                      opticalFlow: nil,
                      submissionMode: previousSource == nil ? .random : .sequential,
                      destinationFrame: destinationFrame
                  ) else {
                throw UpscaleError.processing("Couldn’t prepare a frame.")
            }

            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                processor.process(parameters: parameters) { _, error in
                    if let error { c.resume(throwing: UpscaleError.processing(error.localizedDescription)) } else { c.resume() }
                }
            }
            previousSource = sourceFrame
            previousOutput = destinationFrame

            // RGBA half float → 10-bit YUV for the encoder.
            guard let writerPool = adaptor.pixelBufferPool else {
                throw UpscaleError.cannotWrite("The encoder isn’t ready.")
            }
            let encodeBuffer = try Self.buffer(from: writerPool)
            CVBufferPropagateAttachments(decoded, destinationBuffer)
            CVBufferPropagateAttachments(decoded, encodeBuffer)
            guard VTPixelTransferSessionTransferImage(transfer, from: destinationBuffer, to: encodeBuffer) == noErr else {
                throw UpscaleError.processing("Couldn’t convert a frame.")
            }

            while !videoInput.isReadyForMoreMediaData {
                if isCancelled { throw CancellationError() }
                try await Task.sleep(for: .milliseconds(5))
            }
            guard adaptor.append(encodeBuffer, withPresentationTime: pts) else {
                throw UpscaleError.cannotWrite(writer?.error?.localizedDescription ?? "")
            }
            progress(.upscaling(min(max(pts.seconds / totalSeconds, 0), 1)))
        }
        videoInput.markAsFinished()
    }

    // MARK: - Audio

    private static func copyAudio(_ pairs: [(AVAssetReaderTrackOutput, AVAssetWriterInput)]) async {
        await withTaskGroup(of: Void.self) { group in
            for (output, input) in pairs {
                nonisolated(unsafe) let output = output
                nonisolated(unsafe) let input = input
                group.addTask {
                    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                        let queue = DispatchQueue(label: "audio")
                        input.requestMediaDataWhenReady(on: queue) {
                            while input.isReadyForMoreMediaData {
                                if let sample = output.copyNextSampleBuffer(), input.append(sample) { continue }
                                input.markAsFinished()
                                c.resume()
                                return
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private static func makePool(_ attributes: [String: Any]) throws -> CVPixelBufferPool {
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess, let pool else {
            throw UpscaleError.processing("Couldn’t allocate frame buffers.")
        }
        return pool
    }

    private static func buffer(from pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else {
            throw UpscaleError.processing("Couldn’t allocate a frame buffer.")
        }
        return buffer
    }

    /// Carries the source's color primaries, transfer function and matrix over to the encoder.
    private static func colorProperties(from format: CMFormatDescription?) -> [String: Any]? {
        guard let format,
              let primaries = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries),
              let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction),
              let matrix = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix)
        else { return nil }
        return [
            AVVideoColorPrimariesKey: primaries,
            AVVideoTransferFunctionKey: transfer,
            AVVideoYCbCrMatrixKey: matrix,
        ]
    }
}
