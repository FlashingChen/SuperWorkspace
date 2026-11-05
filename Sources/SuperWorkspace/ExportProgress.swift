import AVFoundation
import Combine

@MainActor
final class ExportProgress: ObservableObject {
    @Published var fraction: Double = 0
    @Published var isCancelled = false
    var session: AVAssetExportSession?

    func cancel() {
        isCancelled = true
        session?.cancelExport()
    }
}
