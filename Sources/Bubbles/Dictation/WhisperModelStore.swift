import BubblesCore
import Combine
import CryptoKit
import Foundation

/// Where the built-in Whisper's model is and "Download model" for a build without it: the file goes to
/// Application Support, its SHA-256 is checked before it is used. Nothing is downloaded without the click.
@MainActor final class WhisperModelStore: NSObject, ObservableObject {
    static let shared = WhisperModelStore()

    enum State: Equatable {
        /// In the app (`bundled`) or downloaded.
        case ready(bundled: Bool)
        case missing
        /// 0…1
        case downloading(Double)
        case verifying
        case failed(String)
    }

    @Published private(set) var state: State = .missing

    /// The model file to load, or nil.
    nonisolated static var modelURL: URL? { WhisperModel.locate(resources: Bundle.main.resourceURL) }

    private var session: URLSession?
    private var task: URLSessionDownloadTask?

    override init() {
        super.init()
        refresh()
    }

    func refresh() {
        switch state {
        case .downloading, .verifying: return
        default: break
        }
        guard let url = Self.modelURL else {
            if !isFailed { state = .missing }
            return
        }
        state = .ready(bundled: url != WhisperModel.defaultDownloadedURL)
    }

    private var isFailed: Bool { if case .failed = state { true } else { false } }

    /// "Download model" (about 550 MB from Hugging Face).
    func download() {
        switch state {
        case .downloading, .verifying, .ready: return
        default: break
        }
        state = .downloading(0)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.downloadTask(with: WhisperModel.downloadURL)
        self.session = session
        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
        finishSession()
        state = .missing
    }

    private func finishSession() {
        session?.finishTasksAndInvalidate()
        session = nil
        task = nil
    }

    private func progress(_ value: Double) {
        guard case .downloading = state else { return }
        state = .downloading(min(1, max(0, value)))
    }

    /// The file is in place under a temporary name: check it, then make it the model.
    private func downloaded(_ part: URL) {
        finishSession()
        state = .verifying
        Task {
            let target = WhisperModel.defaultDownloadedURL
            let ok = await Task.detached(priority: .utility) { () -> Bool in
                guard Self.sha256(of: part) == WhisperModel.sha256 else { return false }
                try? FileManager.default.removeItem(at: target)
                return (try? FileManager.default.moveItem(at: part, to: target)) != nil
            }.value
            if ok {
                state = .ready(bundled: false)
            } else {
                try? FileManager.default.removeItem(at: part)
                state = .failed("The model file arrived damaged — try again")
            }
        }
    }

    private func failed(_ error: Error?) {
        finishSession()
        if let error = error as? URLError, error.code == .cancelled { return }
        let offline = (error as? URLError).map { ClaudeFailure.classify($0) == .offline } ?? false
        state = .failed(offline ? "No internet — the model didn't download" : "The model didn't download — try again")
    }

    nonisolated private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension WhisperModelStore: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : WhisperModel.byteCount
        let value = Double(totalBytesWritten) / Double(total)
        Task { @MainActor in self.progress(value) }
    }

    /// The system deletes `location` when this returns: move it next to the target first.
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let target = WhisperModel.defaultDownloadedURL
        let part = target.appendingPathExtension("part")
        var moved = false
        if (200..<300).contains(status) {
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: part)
            moved = (try? FileManager.default.moveItem(at: location, to: part)) != nil
        }
        Task { @MainActor in moved ? self.downloaded(part) : self.failed(nil) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor in self.failed(error) }
    }
}
