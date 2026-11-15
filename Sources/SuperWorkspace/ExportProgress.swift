import AVFoundation
import Combine

@MainActor
final class ExportProgress: ObservableObject {
    @Published var fraction: Double = 0
    @Published var isCancelled = false
    @Published var phase = "准备导出"
    var task: Task<Void, Never>?
    var session: AVAssetExportSession?

    func begin(_ phase: String) {
        fraction = 0
        self.phase = phase
    }

    func cancel() {
        isCancelled = true
        task?.cancel()
        session?.cancelExport()
    }
}
