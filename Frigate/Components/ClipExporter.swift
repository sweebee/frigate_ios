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
    var isWorking: Bool { if case .working = state { return true } else { return false } }

    /// Fetches `start...end` of `camera` as MP4. Returns the local file.
    func download(client: FrigateClient, camera: String, start: Double, end: Double) async throws -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = "\(camera)_\(f.string(from: Date(timeIntervalSince1970: start))).mp4"
        return try await client.download(client.clipURL(camera: camera, start: start, end: end), fileName: name)
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

/// Small status pill shown while exporting and after it finishes.
struct ExportToast: View {
    let state: ClipExporter.State

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
        HStack(spacing: 8) {
            if let icon { Image(systemName: icon) } else { ProgressView().tint(.white) }
            Text(text).font(.system(size: 14, weight: .semibold)).lineLimit(2)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.black.opacity(0.8), in: Capsule())
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
