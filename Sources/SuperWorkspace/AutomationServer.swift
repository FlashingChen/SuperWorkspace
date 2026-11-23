import Foundation
import RecorderKit

struct AutomationRequest: Codable, Sendable {
    let command: String
    let args: [String: JSONValue]

    init(command: String, args: [String: JSONValue] = [:]) {
        self.command = command
        self.args = args
    }
}

struct AutomationResponse: Codable, Sendable {
    let ok: Bool
    let data: JSONValue?
    let error: String?

    static func success(_ data: JSONValue) -> AutomationResponse {
        AutomationResponse(ok: true, data: data, error: nil)
    }

    static func failure(_ message: String) -> AutomationResponse {
        AutomationResponse(ok: false, data: nil, error: message)
    }
}

/// Local Unix-domain socket control server (`control.sock`) allowing CLI tools
/// and external AI agents to drive headless recording, project inspection, and
/// movie export through the live `AppState`.
final class AutomationServer: @unchecked Sendable {
    static let shared = AutomationServer()

    static var socketDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SuperWorkspace", isDirectory: true)
    }

    static var socketPath: String {
        socketDirectory.appendingPathComponent("control.sock").path
    }

    private let queue = DispatchQueue(label: "superworkspace.automation.server")
    private let stateLock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false
    private weak var appState: AppState?

    private var activeRecordingProjectID: UUID?
    private var activeRecordingMaterialID: UUID?

    private init() {}

    @MainActor
    func start(appState: AppState) {
        self.appState = appState
        let path = Self.socketPath
        let directory = Self.socketDirectory
        stateLock.withLock {
            if running { return }
            running = true
        }
        queue.async { [weak self] in
            self?.runServer(directory: directory, path: path)
        }
    }

    func stop() {
        let fd = stateLock.withLock { () -> Int32 in
            running = false
            let current = listenFD
            listenFD = -1
            return current
        }
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        try? FileManager.default.removeItem(atPath: Self.socketPath)
    }

    private func runServer(directory: URL, path: String) {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            unlink(path)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return }

            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
                close(fd)
                return
            }
            withUnsafeMutableBytes(of: &address.sun_path) { dest in
                dest.copyBytes(from: bytes)
            }
            let bound = withUnsafePointer(to: &address) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                    bind(fd, sock, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, listen(fd, 8) == 0 else {
                close(fd)
                return
            }
            chmod(path, 0o600)
            stateLock.withLock { listenFD = fd }

            while stateLock.withLock({ running }) {
                let client = accept(fd, nil, nil)
                if client < 0 { continue }
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.handleClient(client)
                }
            }
        } catch {
            stateLock.withLock { running = false }
        }
    }

    private func handleClient(_ fd: Int32) {
        defer { close(fd) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
            if buffer[0..<n].contains(UInt8(ascii: "\n")) || data.count > 1_048_576 {
                break
            }
        }
        guard !data.isEmpty else { return }

        let response: AutomationResponse
        do {
            let request = try JSONDecoder().decode(AutomationRequest.self, from: data)
            let sem = DispatchSemaphore(value: 0)
            let box = ResponseBox()
            Task { @MainActor in
                let outcome = await self.dispatch(request)
                box.set(outcome)
                sem.signal()
            }
            sem.wait()
            response = box.get()
        } catch {
            response = .failure("请求解析失败：\(error.localizedDescription)")
        }

        if let encoded = try? JSONEncoder().encode(response) {
            var payload = encoded
            payload.append(UInt8(ascii: "\n"))
            payload.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var written = 0
                while written < payload.count {
                    let count = write(fd, base.advanced(by: written), payload.count - written)
                    if count <= 0 { break }
                    written += count
                }
            }
        }
    }

    @MainActor
    private func dispatch(_ request: AutomationRequest) async -> AutomationResponse {
        guard let state = appState else {
            return .failure("应用状态未就绪。")
        }
        do {
            switch request.command {
            case "status":
                let rec = HeadlessRecorder.shared.status()
                var obj: [String: JSONValue] = [
                    "app": .string("SuperWorkspace"),
                    "pid": .number(Double(ProcessInfo.processInfo.processIdentifier)),
                    "isRecording": .bool(rec.isRecording),
                    "hasScreenRecordingPermission": .bool(rec.hasScreenRecordingPermission),
                    "hasAccessibilityPermission": .bool(rec.hasAccessibilityPermission),
                    "hasAIConnection": .bool(SettingsStore.shared.hasAIConnection),
                ]
                if let target = rec.activeTarget { obj["activeTarget"] = .string(target) }
                if let elapsed = rec.elapsedSeconds { obj["elapsedSeconds"] = .number(elapsed) }
                if let project = state.currentProject {
                    obj["currentProject"] = .object([
                        "id": .string(project.id.uuidString),
                        "name": .string(project.name),
                        "materialCount": .number(Double(project.materials.count)),
                    ])
                }
                return .success(.object(obj))

            case "windows":
                let windows = try await HeadlessRecorder.shared.listWindows()
                let encoded = try JSONEncoder().encode(windows)
                let value = try JSONDecoder().decode(JSONValue.self, from: encoded)
                return .success(value)

            case "resize":
                guard let idNum = request.args["windowID"]?.numberValue,
                      let w = request.args["width"]?.numberValue,
                      let h = request.args["height"]?.numberValue else {
                    return .failure("resize 需要提供 windowID、width 和 height。")
                }
                try await HeadlessRecorder.shared.resizeWindow(
                    windowID: UInt32(idNum),
                    x: request.args["x"]?.numberValue,
                    y: request.args["y"]?.numberValue,
                    width: w,
                    height: h
                )
                return .success(.object(["resized": .bool(true), "windowID": .number(idNum)]))

            case "input_move":
                guard let x = request.args["x"]?.numberValue, let y = request.args["y"]?.numberValue else {
                    return .failure("input_move 需要提供 x 和 y。")
                }
                let duration = request.args["duration"]?.numberValue ?? 0.35
                try await HeadlessRecorder.shared.moveMouse(to: x, y: y, smooth: true, duration: duration)
                return .success(.object(["ok": .bool(true)]))

            case "input_click":
                guard let x = request.args["x"]?.numberValue, let y = request.args["y"]?.numberValue else {
                    return .failure("input_click 需要提供 x 和 y。")
                }
                try await HeadlessRecorder.shared.clickMouse(at: x, y: y, smooth: request.args["smooth"]?.boolValue ?? true)
                return .success(.object(["ok": .bool(true)]))

            case "input_key":
                guard let code = request.args["keyCode"]?.numberValue else {
                    return .failure("input_key 需要提供 keyCode。")
                }
                try await HeadlessRecorder.shared.pressKey(
                    keyCode: UInt16(code),
                    command: request.args["command"]?.boolValue ?? false,
                    shift: request.args["shift"]?.boolValue ?? false
                )
                return .success(.object(["ok": .bool(true)]))

            case "input_paste":
                guard let text = request.args["text"]?.stringValue else {
                    return .failure("input_paste 需要提供 text。")
                }
                try await HeadlessRecorder.shared.pasteText(text)
                return .success(.object(["ok": .bool(true)]))

            case "input_type":
                guard let text = request.args["text"]?.stringValue else {
                    return .failure("input_type 需要提供 text。")
                }
                let interval = request.args["interval"]?.numberValue ?? 0.12
                try await HeadlessRecorder.shared.typeText(text, interval: interval)
                return .success(.object(["ok": .bool(true)]))

            case "input_drag":
                guard let x0 = request.args["fromX"]?.numberValue,
                      let y0 = request.args["fromY"]?.numberValue,
                      let x1 = request.args["toX"]?.numberValue,
                      let y1 = request.args["toY"]?.numberValue else {
                    return .failure("input_drag 需要提供 fromX、fromY、toX、toY。")
                }
                let duration = request.args["duration"]?.numberValue ?? 0.45
                try await HeadlessRecorder.shared.dragMouse(from: x0, y0: y0, to: x1, y1: y1, duration: duration)
                return .success(.object(["ok": .bool(true)]))

            case "screenshot":
                guard let out = request.args["out"]?.stringValue, !out.isEmpty else {
                    return .failure("screenshot 需要提供 out 路径。")
                }
                let result = try await HeadlessRecorder.shared.captureScreenshot(
                    to: URL(fileURLWithPath: out),
                    windowID: request.args["windowID"]?.numberValue.map { UInt32($0) },
                    appName: request.args["appName"]?.stringValue
                )
                return .success(.object([
                    "outputPath": .string(result.outputPath),
                    "x": .number(Double(result.x)),
                    "y": .number(Double(result.y)),
                    "width": .number(Double(result.width)),
                    "height": .number(Double(result.height)),
                ]))

            case "record_start":
                if let projectName = request.args["projectName"]?.stringValue, !projectName.isEmpty {
                    if let existing = state.projects.first(where: { $0.name == projectName }) {
                        state.selectedProjectID = existing.id
                    } else {
                        state.createProject(name: projectName)
                    }
                } else if state.currentProject == nil {
                    state.createProject(name: "AI 录制演示")
                }
                guard let project = state.currentProject else {
                    return .failure("无法创建或定位目标项目。")
                }
                guard !project.isFrozen else {
                    return .failure("当前项目已冻结，请先取消冻结或切换到其他项目。")
                }

                let materialID = UUID()
                var placeholder = Material()
                placeholder.id = materialID
                let outputURL = ProjectLayout.source(placeholder, in: project)

                let startReq = HeadlessRecordStartRequest(
                    windowID: request.args["windowID"]?.numberValue.map { UInt32($0) },
                    appName: request.args["appName"]?.stringValue,
                    displayID: request.args["displayID"]?.numberValue.map { UInt32($0) },
                    systemAudio: request.args["systemAudio"]?.boolValue ?? true,
                    fps: request.args["fps"]?.numberValue.map { Int($0) } ?? 60
                )
                let started = try await HeadlessRecorder.shared.start(request: startReq, outputURL: outputURL)
                activeRecordingProjectID = project.id
                activeRecordingMaterialID = materialID
                return .success(.object([
                    "projectID": .string(project.id.uuidString),
                    "projectName": .string(project.name),
                    "materialID": .string(materialID.uuidString),
                    "targetKind": .string(started.targetKind),
                    "targetTitle": .string(started.targetTitle),
                    "width": .number(Double(started.width)),
                    "height": .number(Double(started.height)),
                    "outputPath": .string(started.outputPath),
                ]))

            case "record_stop":
                let wantsMotion = request.args["wantsMotion"]?.boolValue ?? false
                let editingPrompt = request.args["editingPrompt"]?.stringValue
                let styled = request.args["styled"]?.boolValue ?? true
                let stopped = try await HeadlessRecorder.shared.stop(styled: styled)
                guard let projectID = activeRecordingProjectID,
                      let materialID = activeRecordingMaterialID else {
                    return .failure("找不到对应的录制项目上下文。")
                }
                activeRecordingProjectID = nil
                activeRecordingMaterialID = nil

                try await state.registerHeadlessRecording(
                    projectID: projectID,
                    materialID: materialID,
                    outputURL: URL(fileURLWithPath: stopped.outputPath),
                    duration: stopped.duration,
                    wantsMotion: wantsMotion,
                    editingPrompt: editingPrompt
                )

                var obj: [String: JSONValue] = [
                    "projectID": .string(projectID.uuidString),
                    "materialID": .string(materialID.uuidString),
                    "outputPath": .string(stopped.outputPath),
                    "duration": .number(stopped.duration),
                    "pointerEventCount": .number(Double(stopped.pointerEventCount)),
                    "autoZoomCount": .number(Double(stopped.autoZoomCount)),
                ]
                if let warning = stopped.warning { obj["warning"] = .string(warning) }
                return .success(.object(obj))

            case "project":
                guard let project = state.currentProject else {
                    return .failure("当前没有选中项目。")
                }
                let materials: [JSONValue] = project.materials.enumerated().map { idx, m in
                    .object([
                        "index": .number(Double(idx + 1)),
                        "id": .string(m.id.uuidString),
                        "title": .string(m.displayTitle(index: idx)),
                        "duration": .number(m.duration),
                        "exportState": .string(m.exportState.rawValue),
                        "transcriptState": .string(m.transcriptState.rawValue),
                        "motionState": .string(m.motionState.rawValue),
                        "subtitleCount": .number(Double(m.subtitles.count)),
                    ])
                }
                var obj: [String: JSONValue] = [
                    "id": .string(project.id.uuidString),
                    "name": .string(project.name),
                    "isFrozen": .bool(project.isFrozen),
                    "materials": .array(materials),
                ]
                if let last = project.lastExportName {
                    obj["lastExportPath"] = .string(ProjectLayout.directory(for: project).appendingPathComponent(last).path)
                }
                return .success(.object(obj))

            case "export":
                guard let projectID = state.selectedProjectID else {
                    return .failure("当前没有选中项目。")
                }
                let includeSubtitles = request.args["includeSubtitles"]?.boolValue ?? false
                let exportSRT = request.args["exportSRT"]?.boolValue ?? false
                let exportedURL = try await state.exportProjectHeadless(
                    projectID: projectID,
                    includeSubtitles: includeSubtitles,
                    exportSRT: exportSRT
                )
                return .success(.object([
                    "outputPath": .string(exportedURL.path),
                ]))

            default:
                return .failure("不支持的命令：\(request.command)")
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}

private final class ResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AutomationResponse = .failure("内部错误")

    func set(_ next: AutomationResponse) {
        lock.withLock { value = next }
    }

    func get() -> AutomationResponse {
        lock.withLock { value }
    }
}
