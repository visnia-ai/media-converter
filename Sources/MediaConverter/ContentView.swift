import SwiftUI
import UniformTypeIdentifiers
#if canImport(MediaCore)
import MediaCore
#endif

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 14) {
                FolderDropView(title: "Source", icon: "folder", url: model.source,
                               disabled: model.isRunning, choose: { model.choose(source: true) },
                               receive: { model.select($0, source: true) })
                Image(systemName: "arrow.right").foregroundStyle(.tertiary).accessibilityHidden(true)
                FolderDropView(title: "Destination", icon: "folder.badge.plus", url: model.destination,
                               disabled: model.isRunning, choose: { model.choose(source: false) },
                               receive: { model.select($0, source: false) })
            }
            HStack(alignment: .top, spacing: 30) {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Images", selection: $model.imageFormat) {
                        ForEach(ImageFormat.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if model.imageFormat == .png {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Lossless PNG").font(.callout)
                            Text("Preserves image detail and transparency. Quality adjustment is not needed.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        QualityControl(title: "Image quality", value: $model.imageQuality)
                    }
                    imageEstimate
                }
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Videos", selection: .constant(VideoFormat.mp4)) {
                        Text("MP4").tag(VideoFormat.mp4)
                    }
                    QualityControl(title: "Video quality", value: $model.videoQuality)
                }
            }
            .disabled(model.isRunning)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if let snapshot = model.snapshot {
                    if snapshot.phase == .scanning {
                        ProgressView().controlSize(.small)
                        Text("Scanning…").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ProgressView(value: snapshot.progress).accessibilityLabel("Conversion progress")
                        HStack {
                            Text("\(snapshot.completedImages)/\(snapshot.totalImages) images · \(snapshot.completedVideos)/\(snapshot.totalVideos) videos processed")
                            Spacer()
                            if model.isCancelling { Text("Cancelling…") }
                            else if snapshot.phase == .cancelled { Text("Cancelled") }
                        }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        if !model.isRunning { summary(snapshot) }
                    }
                } else {
                    Text("Images → \(model.imageFormat.rawValue)   ·   Videos → MP4")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            }.frame(minHeight: 42, alignment: .top)
            HStack {
                if let snapshot = model.snapshot, !model.isRunning, !snapshot.issues.isEmpty {
                    Button("Details", systemImage: "info.circle") { showDetails = true }.buttonStyle(.borderless)
                }
                Spacer()
                if model.isRunning {
                    Button("Cancel", role: .cancel) { model.cancel() }.disabled(model.isCancelling)
                } else {
                    Button("Convert", action: model.start).buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.source == nil || model.destination == nil)
                }
            }
        }
        .padding(28)
        .sheet(isPresented: $showDetails) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Conversion details").font(.headline)
                List(Array((model.snapshot?.issues ?? []).enumerated()), id: \.offset) { _, issue in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(issue.path).fontWeight(.medium)
                        Text(issue.message).font(.caption).foregroundStyle(.secondary)
                    }.textSelection(.enabled)
                }
                HStack { Spacer(); Button("Done") { showDetails = false }.keyboardShortcut(.defaultAction) }
            }.padding(20).frame(width: 560, height: 350)
        }
    }

    private var imageEstimate: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                if let estimate = model.imageEstimate {
                    if let average = estimate.averageOutputBytes {
                        Text("Est. avg \(ByteCountFormatter.string(fromByteCount: average, countStyle: .file))\(sizeChange(estimate))")
                            .foregroundStyle(.primary)
                        Text("\(estimate.largerCount)/\(estimate.measuredCount) sampled files larger")
                        if estimate.skippedCount + estimate.failedCount + estimate.unreadableCount > 0 {
                            Text("\(estimate.skippedCount) skipped · \(estimate.failedCount) failed\(estimate.unreadableCount > 0 ? " · \(estimate.unreadableCount) unreadable" : "")")
                        }
                    } else if estimate.discoveredImages == 0 {
                        Text(estimate.unreadableCount > 0 ? "No readable images found." : "No images found.")
                    } else {
                        Text("No sample images could be converted.")
                        Text("\(estimate.skippedCount) skipped · \(estimate.failedCount) failed")
                    }
                }
                if model.isEstimating && !model.isRunning {
                    if let progress = model.estimateProgress, progress.phase == .measuring {
                        Text("Sampling \(progress.completed)/\(progress.total)…")
                    } else {
                        Text(model.imageEstimate == nil ? "Sampling images…" : "Checking sample…")
                    }
                } else if let error = model.estimateError {
                    Text(error)
                } else if model.source == nil {
                    Text("Choose a source for a size estimate.")
                } else if model.imageEstimate == nil {
                    Text("Estimate paused.")
                }
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if model.source != nil {
                Button { model.scheduleEstimate(immediate: true) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(model.isRunning || model.isEstimating)
                    .accessibilityLabel("Refresh size estimate")
                    .help("Resample the source folder and check cached measurements.")
            }
        }
        .help("Measured using up to 50 images spread across formats, resolutions, and sizes. The average and size change use successfully converted samples only. Other files may differ; an estimate is not a size guarantee. Temporary samples never go into your destination.")
    }

    private func sizeChange(_ estimate: ImageSizeEstimate) -> String {
        guard let change = estimate.sizeChange else { return "" }
        guard change != 0 else { return " · same size" }
        let percent = Int((abs(change) * 100).rounded())
        return " · \(percent == 0 ? "<1" : String(percent))% \(change < 0 ? "smaller" : "larger")"
    }

    private func summary(_ snapshot: BatchSnapshot) -> some View {
        HStack(spacing: 8) {
            Text("\(snapshot.converted) converted · \(snapshot.skipped) skipped · \(snapshot.failed) failed")
            Spacer()
            if snapshot.converted > 0 {
                let difference = snapshot.sourceBytes - snapshot.outputBytes
                Text("\(ByteCountFormatter.string(fromByteCount: abs(difference), countStyle: .file)) \(difference >= 0 ? "saved" : "larger")")
            }
        }.font(.caption).foregroundStyle(.secondary)
    }
}

private struct QualityControl: View {
    let title: String
    @Binding var value: Double
    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text("\(Int(value))").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: 1...100, step: 1).accessibilityLabel(title)
                .help("Higher values retain more detail and usually create larger files. 100 is not guaranteed lossless.")
            HStack {
                Text("Smaller files")
                Spacer()
                Text("Higher quality")
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

private struct FolderDropView: View {
    let title: String
    let icon: String
    let url: URL?
    let disabled: Bool
    let choose: () -> Void
    let receive: (URL) -> Void
    @State private var targeted = false

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 30, weight: .light)).foregroundStyle(.tint)
                Text(title).font(.headline)
                Text(url?.lastPathComponent ?? "Drop folder or choose")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity).frame(height: 125)
            .background(targeted ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(
                targeted ? Color.accentColor : Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: url == nil ? [5, 4] : [])))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain).disabled(disabled)
        .help(url?.path ?? "Choose a \(title.lowercased()) folder")
        .accessibilityLabel("\(title) folder")
        .dropDestination(for: URL.self) { urls, _ in
            guard !disabled, urls.count == 1, let url = urls.first, url.isFileURL else { return false }
            receive(url)
            return true
        } isTargeted: { targeted = $0 && !disabled }
    }
}
