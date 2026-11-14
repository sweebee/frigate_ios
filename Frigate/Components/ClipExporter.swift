import Photos
import SwiftUI

/// Downloads a recording range from Frigate and saves it to the photo library.
@Observable @MainActor
final class ClipExporter {
    enum State: Equatable {
        case idle
        case working(String)
        case done(String)
        case failed(String)
    }

    var state: State = .idle
    /// Of the download in progress: bytes received and expected (0 when unknown).
    var received: Int64 = 0
    var expected: Int64 = 0
    /// 0...1 when the size is known.
    var fraction: Double? { expected > 0 ? min(1, Double(received) / Double(expected)) : nil }
    var isWorking: Bool { if case .working = state { return true } else { return false } }

    /// Fetches `start...end` of `camera` as MP4. Returns the local file.
    func download(client: FrigateClient, camera: String, start: Double, end: Double) async throws -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = "\(camera)_\(f.string(from: Date(timeIntervalSince1970: start))).mp4"
        return try await downloadFile(client: client, url: client.clipURL(camera: camera, start: start, end: end), fileName: name)
    }

    /// Downloads with the progress shown in the pill.
    func downloadFile(client: FrigateClient, url: URL, fileName: String) async throws -> URL {
        received = 0
        expected = 0
        defer { received = 0; expected = 0 }
        return try await client.download(url, fileName: fileName) { got, total in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Only forward: a late report must not move the bar back.
                if got >= self.received { self.received = got; self.expected = total }
            }
        }
    }

    func saveToPhotos(client: FrigateClient, camera: String, start: Double, end: Double) async {
        state = .working(L("Saving \(FrigateFormat.duration(end - start)) clip…"))
        do {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                state = .failed(L("Allow Tender to add photos in Settings to save clips."))
                return
            }
            let file = try await download(client: client, camera: camera, start: start, end: end)
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: file)
            }
            try? FileManager.default.removeItem(at: file)
            state = .done(L("Saved to Photos"))
        } catch {
            state = .failed(error.localizedDescription)
        }
        try? await Task.sleep(for: .seconds(2.5))
        if case .working = state {} else { state = .idle }
    }
}

extension ClipExporter {
    /// Has Frigate export the span on the server, where it stays (Frigate's Exports page, and
    /// the Exports row in Explore).
    func saveToFrigate(client: FrigateClient, camera: String, start: Double, end: Double, name: String) async {
        state = .working(L("Saving to Frigate…"))
        do {
            try await client.startExport(camera: camera, start: start, end: end, name: name)
            state = .done(L("Saved to Frigate's exports"))
        } catch {
            state = .failed(error.localizedDescription)
        }
        try? await Task.sleep(for: .seconds(2.5))
        if case .working = state {} else { state = .idle }
    }

    /// "Voortuin, 13 Nov 15:06": a name for an export made from the app.
    static func exportName(camera: String, displayName: String?, start: Double, label: String? = nil) -> String {
        let date = Date(timeIntervalSince1970: start)
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM HH:mm")
        let cam = displayName ?? FrigateFormat.prettyName(camera)
        if let label { return "\(FrigateFormat.labelName(label).capitalizedFirst) · \(cam), \(f.string(from: date))" }
        return "\(cam), \(f.string(from: date))"
    }
}

/// Small status pill shown while exporting and after it finishes; with a download's progress.
struct ExportToast: View {
    let state: ClipExporter.State
    var exporter: ClipExporter? = nil

    init(state: ClipExporter.State) { self.state = state }
    init(exporter: ClipExporter) { self.state = exporter.state; self.exporter = exporter }

    var body: some View {
        Group {
            switch state {
            case .idle: EmptyView()
            case .working(let text): pill(text, icon: nil)
            case .done(let text): pill(text, icon: "checkmark.circle.fill")
            case .failed(let text): pill(text, icon: "exclamationmark.triangle.fill")
            }
        }
        .animation(.easeOut(duration: 0.2), value: state)
    }

    private func pill(_ text: String, icon: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon) } else { ProgressView().tint(.white) }
                Text(text).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                if icon == nil, let exporter, exporter.received > 0 {
                    Text(amount(exporter)).font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            // A bar while downloading (Frigate first builds the clip, so it starts after a moment).
            if icon == nil, let exporter, exporter.received > 0 {
                if let f = exporter.fraction {
                    ProgressView(value: f).tint(Theme.accent).frame(width: 220)
                } else {
                    ProgressView().progressViewStyle(.linear).tint(Theme.accent).frame(width: 220)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 20))
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func amount(_ e: ClipExporter) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useMB]
        if let fraction = e.fraction { return "\(Int((fraction * 100).rounded()))%" }
        return f.string(fromByteCount: e.received)
    }
}
