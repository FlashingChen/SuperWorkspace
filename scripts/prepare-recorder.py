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
    if path.name == 'RecorderPanelController.swift':
        start = content.index('@MainActor\nfinal class DogSCApplicationDelegate:')
        end = content.index('/// Pure geometry/style policy', start)
        content = content[:start] + content[end:]
        content = replace_once(content,
            '''        DispatchQueue.main.async {
            (NSApplication.shared.delegate as? DogSCApplicationDelegate)?
                .refreshMainMenuBindings()
        }''', '')
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
    if path.name == 'FirstLaunchIntroduction.swift':
        content = replace_once(content, 'Self.wordmark("DogSC",', 'Self.wordmark(AppIdentity.displayName,')
    if path.name == 'EditorView.swift':
        content = replace_once(content, '            ExportSheet(\n', '            IntegratedExportSheet(\n')
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
