#!/usr/bin/env python3
"""Prepare the local recording sources as an in-process library."""
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
subprocess.run([sys.executable, str(root / 'scripts' / 'fetch-recorder.py')], check=True)
source = root / 'dogsc-source' / 'Sources' / 'DogSCApp'
target = root / '.build' / 'IntegratedRecorder'
if not source.is_dir():
    raise SystemExit('Missing local recording sources: dogsc-source')
target.mkdir(parents=True, exist_ok=True)
expected = set()

def replace_once(content, old, new):
    if content.count(old) != 1:
        raise SystemExit(f'Unsupported recorder source layout: {old[:60]!r}')
    return content.replace(old, new, 1)

for path in source.glob('*.swift'):
    if path.name == 'AppUpdateController.swift':
        continue
    content = path.read_text()
    if path.name == 'DogSCApp.swift':
        start = content.index('@main\nenum DogSCApplication')
        end = content.index('/// The menu and settings entry', start)
        content = content[:start] + content[end:]
        content = replace_once(content, '    static func bringCurrentWindowFront() {', '''    static var integratedRecorderFrame: NSRect? {
        guard let model, !model.showsRequiredPermissionGate else { return nil }
        return recorderPanelController?.window.frame
    }

    static func presentIntegratedSession() -> NSRect? {
        guard let model else { return nil }
        apply(phase: model.phase, model: model)
        recorderPanelController?.window.contentView?.layoutSubtreeIfNeeded()
        return integratedRecorderFrame
    }

    static func bringCurrentWindowFront() {''')
        content = replace_once(content, '''            .sink { [weak model] in
                guard let model else { return }
                apply(phase: model.phase, model: model)
            }''', '''            .sink { [weak model] in
                guard let model, self.model === model else { return }
                apply(phase: model.phase, model: model)
            }''')
        content = replace_once(content, '        RecorderMemoController.shared.shutdown()',
            '        AppSettingsWindowController.shared.hideForFirstLaunchGuide()\n        RecorderMemoController.shared.shutdown()')
    if path.name == 'RecorderPanelController.swift':
        start = content.index('@MainActor\nfinal class DogSCApplicationDelegate:')
        end = content.index('/// Pure geometry/style policy', start)
        content = content[:start] + content[end:]
        content = replace_once(content,
            '''        DispatchQueue.main.async {
            (NSApplication.shared.delegate as? DogSCApplicationDelegate)?
                .refreshMainMenuBindings()
        }''', '')
        content = replace_once(content, 'setupSize = NSSize(width: 374, height: 56)',
            'setupSize = NSSize(width: 570, height: 56)')
    if path.name == 'AppModel.swift':
        content = replace_once(content, 'phase = .recordingComplete', 'phase = .recordingComplete\n                editCompletedRecording()')
        content = replace_once(content,
            '        if selectedTarget.source == .device { refreshCaptureDevices() }',
            """        if AppPreferences.isDefaultMicrophoneRecordingEnabled, !configuration.recordsMicrophone {
            errorMessage = "麦克风尚未就绪。请点击麦克风选择输入设备，并确认系统已允许麦克风访问。"
            return
        }
        if selectedTarget.source == .device { refreshCaptureDevices() }""")
    if path.name == 'AppModel+ProjectCommands.swift':
        # Keep the recorder's normal close command. The host return action
        # follows the same save/discard decisions and only leaves on success.
        start = content.index('    func requestCloseProject() {')
        end = content.index('    func requestDeleteCurrentProject()', start)
        close_command = content[start:end].replace(
            'func requestCloseProject() {',
            'func requestCloseProject(onClosing: @escaping () -> Void = {}) {', 1)
        close_command = replace_once(close_command, '        guard phase == .editor else { return }',
            '        guard phase == .editor else { return }\n        defer { if phase != .editor { onClosing() } }')
        for indent in ('                ', '            '):
            decision_guard = f'\n{indent}      self.currentSession?.packageURL == sessionURL else {{ return }}'
            close_command = replace_once(close_command, decision_guard,
                f'{decision_guard}\n{indent}defer {{ if self.phase != .editor {{ onClosing() }} }}')
        content = content[:start] + close_command + content[end:]
        content = replace_once(content,
            '        openPrivacySettings(section: permission.settingsSection)',
            """        switch permission {
        case .screenRecording:
            if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        case .accessibility:
            if !AXIsProcessTrusted() {
                let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
        }
        openPrivacySettings(section: permission.settingsSection)""")
        fallback = '} ?? availableMicrophones.first'
        if content.count(fallback) != 2:
            raise SystemExit('Unsupported microphone default selection layout.')
        content = content.replace(fallback, '} ?? WorkspaceInputPolicy.defaultMicrophone(in: availableMicrophones)')
    if path.name == 'RecorderSetupSurface.swift':
        content = replace_once(content, 'let all = CaptureSource.allCases', 'let all = CaptureSource.allCases.filter { $0 != .device }')
        content = replace_once(content, '            recordButton.padding(.leading, 4)',
            '            WorkspaceReturnButton().padding(.horizontal, 4)\n            recordButton.padding(.leading, 4)')
        content = replace_once(content,
            'RecorderPopoverButton(id: "microphone", title: "麦克风", width: 44, height: 44)',
            'RecorderPopoverButton(id: "microphone", title: "麦克风", width: 132, height: 44)')
        content = replace_once(content,
            '                    RecorderMicrophoneGlyph(meter: model.microphoneInputLevel, enabled: model.configuration.recordsMicrophone)',
            """                    HStack(spacing: 0) {
                        RecorderMicrophoneGlyph(meter: model.microphoneInputLevel, enabled: model.configuration.recordsMicrophone)
                            .frame(width: 44, height: 44)
                        Text(model.configuration.recordsMicrophone ? "麦克风开启" : "麦克风关闭")
                            .font(.appUI(size: 11, weight: .medium))
                            .foregroundStyle(model.configuration.recordsMicrophone ? RecorderStyle.ink : RecorderStyle.muted)
                    }
                    .frame(width: 132, height: 44)""")
    if path.name == 'PermissionOnboardingContent.swift':
        content = replace_once(content, 'Text("DogSC")', 'Text(AppIdentity.displayName)')
        content = replace_once(content, '''                    .foregroundStyle(RecorderStyle.ink)
            }
            .opacity(presentation.isIntroAnimating ? 0 : 1)''', '''                    .foregroundStyle(RecorderStyle.ink)
                Spacer()
                if !isReview { WorkspaceReturnButton() }
            }
            .opacity(presentation.isIntroAnimating ? 0 : 1)''')
    if path.name == 'RecorderPermissionView.swift':
        content = replace_once(content,
            '        if wasReview { WindowCoordinator.resumeWorkspaceAfterPermissionGuide(replay: false) }',
            '''        if wasReview {
            WindowCoordinator.resumeWorkspaceAfterPermissionGuide(replay: false)
        } else {
            DispatchQueue.main.async { WorkspaceRecorder.shared.requestWorkspaceReturn() }
        }''')
    if path.name == 'FirstLaunchIntroduction.swift':
        content = replace_once(content, 'Self.wordmark("DogSC",', 'Self.wordmark(AppIdentity.displayName,')
    if path.name == 'EditorView.swift':
        content = replace_once(content, '            ExportSheet(\n', '            IntegratedExportSheet(\n')
        content = replace_once(content, '''                EditorToolbarDivider()
                Button { presentExport(scope: .fullProject) } label: {''', '''                EditorToolbarDivider()
                WorkspaceReturnButton().disabled(isCropping)
                Button { presentExport(scope: .fullProject) } label: {''')
    dest = target / path.name
    if not dest.exists() or dest.read_text() != content:
        dest.write_text(content)
    expected.add(path.name)
for path in (root / 'Integration').glob('*.swift'):
    dest = target / path.name
    if not dest.exists() or dest.read_text() != path.read_text():
        shutil.copyfile(path, dest)
    expected.add(path.name)
for path in target.glob('*.swift'):
    if path.name not in expected:
        path.unlink()
print('Prepared integrated recording library.')
