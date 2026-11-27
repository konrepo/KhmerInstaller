import Foundation
import Combine
import ZsignC

enum TVOSDownloadError: LocalizedError {
    case invalidURL
    case invalidResponse
    case invalidIPA
    case fileTooLarge
    case alreadyDownloading

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid IPA download URL."
        case .invalidResponse:
            return "Unable to download the IPA."
        case .invalidIPA:
            return "The downloaded file is not a valid IPA archive."
        case .fileTooLarge:
            return "The IPA exceeds the allowed download size."
        case .alreadyDownloading:
            return "A download is already in progress."
        }
    }
}

private final class TVOSDownloadDelegate:
    NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    var onProgress: (@Sendable (Double) -> Void)?
    var onExcessiveSize: (@Sendable () -> Void)?

    private let maximumSize: Int64 = 2_000_000_000

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesWritten > maximumSize ||
            totalBytesExpectedToWrite > maximumSize {
            onExcessiveSize?()
            downloadTask.cancel()
            return
        }

        guard totalBytesExpectedToWrite > 0 else {
            return
        }

        let value = min(
            1.0,
            Double(totalBytesWritten) /
                Double(totalBytesExpectedToWrite)
        )

        onProgress?(value)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // URLSession's async download API manages the temporary file.
    }
}

@MainActor
final class TVOSAppDownloader: ObservableObject {

    @Published private(set) var isDownloading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var errorMessage: String?

    private var session: URLSession?
    private var activeTask: Task<URL, Error>?
    private var cancellationRequested = false
    private var sizeLimitExceeded = false
    private let maximumSize: Int64 = 2_000_000_000

    func download(
        variant: TVOSAppVariant
    ) async throws -> URL {

        guard !isDownloading else {
            throw TVOSDownloadError.alreadyDownloading
        }

        guard variant.ipaURL.scheme?.lowercased() == "https",
              variant.fileName.lowercased().hasSuffix(".ipa")
        else {
            throw TVOSDownloadError.invalidURL
        }

        isDownloading = true
        progress = 0
        errorMessage = nil
        cancellationRequested = false
        sizeLimitExceeded = false

        defer {
            isDownloading = false
            activeTask = nil
            session?.invalidateAndCancel()
            session = nil
        }

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600

        let delegate = TVOSDownloadDelegate()

        delegate.onProgress = { [weak self] value in
            Task { @MainActor [weak self] in
                guard let self,
                      self.isDownloading,
                      !self.cancellationRequested else { return }
                self.progress = value
            }
        }

        delegate.onExcessiveSize = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sizeLimitExceeded = true
                self.cancel()
            }
        }

        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )

        self.session = session

        let task = Task<URL, Error> {
            let (temporaryURL, response) = try await session.download(
                from: variant.ipaURL
            )

            try Task.checkCancellation()

            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  http.url?.scheme?.lowercased() == "https"
            else {
                throw TVOSDownloadError.invalidResponse
            }

            let fm = FileManager.default

            let attributes = try fm.attributesOfItem(
                atPath: temporaryURL.path
            )

            let size = (attributes[.size] as? NSNumber)?
                .int64Value ?? 0

            guard size > 0 else {
                throw TVOSDownloadError.invalidIPA
            }

            guard size <= maximumSize else {
                throw TVOSDownloadError.fileTooLarge
            }

            guard let inspected = KIInspectIPA(
                temporaryURL.path
            ),
                  let bundleID = inspected["bundleID"] as? String,
                  !bundleID.isEmpty
            else {
                throw TVOSDownloadError.invalidIPA
            }

            try Task.checkCancellation()

            let directory = fm.temporaryDirectory
                .appendingPathComponent(
                    "KhmerInstaller-AppLibrary",
                    isDirectory: true
                )

            try fm.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )

            let destination = directory.appendingPathComponent(
                UUID().uuidString + ".ipa"
            )

            try Task.checkCancellation()

            try fm.moveItem(
                at: temporaryURL,
                to: destination
            )

            if Task.isCancelled || cancellationRequested {
                try? fm.removeItem(at: destination)
                throw CancellationError()
            }

            return destination
        }

        activeTask = task

        do {
            let url = try await task.value

            guard !cancellationRequested else {
                try? FileManager.default.removeItem(at: url)
                throw CancellationError()
            }

            progress = 1
            return url

        } catch {
            if sizeLimitExceeded {
                errorMessage =
                    TVOSDownloadError.fileTooLarge.localizedDescription
                throw TVOSDownloadError.fileTooLarge
            }

            if cancellationRequested {
                errorMessage = "Download canceled."
                throw CancellationError()
            }

            errorMessage = error.localizedDescription
            throw error
        }
    }

    func cancel() {
        guard isDownloading else { return }

        cancellationRequested = true
        activeTask?.cancel()
        session?.invalidateAndCancel()
    }
}
