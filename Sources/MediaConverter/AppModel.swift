import SwiftUI
import AppKit
#if canImport(MediaCore)
import MediaCore
#endif

@MainActor @Observable
final class AppModel {
    var source: URL?
    var destination: URL?
    var imageFormat: ImageFormat = .heic { didSet { if oldValue != imageFormat { scheduleEstimate() } } }
    var imageQuality = 95.0 { didSet { if oldValue != imageQuality { scheduleEstimate() } } }
    var videoQuality = 95.0
    var snapshot: BatchSnapshot?
    var isRunning = false
    var isCancelling = false
    var error: String?
    var imageEstimate: ImageSizeEstimate?
    var estimateProgress: ImageEstimateProgress?
    var estimateError: String?
    var isEstimating = false
    var hasBackgroundWork: Bool { task != nil || estimateTask != nil }
    private var task: Task<Void, Never>?
    private var estimateTask: Task<Void, Never>?
    private var estimateRequest = UUID()
    private struct EstimateKey: Hashable {
        let source: URL
        let format: ImageFormat
        let quality: Int
    }
    private var estimateCache: [EstimateKey: ImageSizeEstimate] = [:]
    private var estimateCacheOrder: [EstimateKey] = []
    private var sourceScope = false
    private var destinationScope = false
    private let coordinator = BatchCoordinator()
    private let estimator = ImageSizeEstimator()

    func choose(source isSource: Bool) {
        guard !isRunning else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = !isSource
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { select(url, source: isSource) }
    }

    func select(_ url: URL, source isSource: Bool) {
        guard !isRunning else { return }
        let access = url.startAccessingSecurityScopedResource()
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
              values.isDirectory == true, values.isPackage != true else {
            if access { url.stopAccessingSecurityScopedResource() }
            error = "Drop a folder here."
            return
        }
        if isSource {
            if sourceScope { source?.stopAccessingSecurityScopedResource() }
            source = url; sourceScope = access
        } else {
            if destinationScope { destination?.stopAccessingSecurityScopedResource() }
            destination = url; destinationScope = access
        }
        error = nil; snapshot = nil
        if isSource { scheduleEstimate(immediate: true) }
    }

    func start() {
        guard !isRunning, let source, let destination else { return }
        error = nil; isRunning = true; isCancelling = false
        snapshot = BatchSnapshot()
        let pendingEstimate = estimateTask
        pendingEstimate?.cancel()
        let options = ConversionOptions(imageFormat: imageFormat, imageQuality: imageQuality / 100, videoQuality: videoQuality / 100)
        task = Task { [self] in
            do {
                await pendingEstimate?.value
                try Task.checkCancellation()
                _ = try await coordinator.run(source: source, destination: destination, options: options) { [weak self] value in
                    await self?.update(value)
                }
            } catch is CancellationError {
                snapshot?.phase = .cancelled
            } catch {
                self.error = (error as? ConversionError)?.localizedDescription ?? "Unable to access the selected folders."
                snapshot = nil
            }
            isRunning = false; isCancelling = false; task = nil
        }
    }

    private func update(_ value: BatchSnapshot) { snapshot = value }
    func cancel() { isCancelling = true; task?.cancel() }

    func cancelAllWork() {
        estimateTask?.cancel()
        if isRunning { cancel() }
    }

    func scheduleEstimate(immediate: Bool = false) {
        guard !isRunning, let source else { return }
        let previous = estimateTask
        previous?.cancel()
        let request = UUID()
        estimateRequest = request
        let key = EstimateKey(source: source, format: imageFormat, quality: Int(imageQuality))
        // Show a previous measurement immediately while checking its source fingerprints in the background.
        imageEstimate = estimateCache[key]
        estimateProgress = nil; estimateError = nil; isEstimating = true
        estimateTask = Task { [self] in
            let access = source.startAccessingSecurityScopedResource()
            defer {
                if access { source.stopAccessingSecurityScopedResource() }
                if estimateRequest == request { isEstimating = false; estimateTask = nil }
            }
            // Wait for an in-flight synchronous image encode to finish before starting another pool.
            await previous?.value
            do {
                if !immediate { try await Task.sleep(for: .milliseconds(400)) }
                try Task.checkCancellation()
                let value = try await estimator.estimate(source: source, format: key.format, quality: key.quality) { [weak self] value in
                    await self?.updateEstimateProgress(value, request: request)
                }
                try Task.checkCancellation()
                guard estimateRequest == request else { return }
                imageEstimate = value
                if estimateCache[key] == nil { estimateCacheOrder.append(key) }
                estimateCache[key] = value
                if estimateCacheOrder.count > 24 { estimateCache.removeValue(forKey: estimateCacheOrder.removeFirst()) }
            } catch is CancellationError {
                // A newer slider value or a full conversion superseded this trial.
            } catch {
                guard estimateRequest == request else { return }
                imageEstimate = nil
                estimateError = "Estimate unavailable. Try refreshing."
            }
        }
    }

    private func updateEstimateProgress(_ progress: ImageEstimateProgress, request: UUID) {
        guard estimateRequest == request, !isRunning else { return }
        estimateProgress = progress
    }
}
