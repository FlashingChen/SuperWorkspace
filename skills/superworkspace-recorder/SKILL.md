---
name: superworkspace-recorder
description: Drive the running SuperWorkspace macOS app via its local CLI to inspect windows, take screenshots, smoothly control mouse and keyboard, record 60fps screen or window demos, render styled rough cuts (wallpaper, rounded shadow, vector cursor, Auto-Zoom), and export final MP4/SRT videos.
---

# SuperWorkspace Recorder CLI Skill

Use this skill when asked to record a macOS app demo, software walkthrough, or terminal tutorial and produce a polished rough-cut or final MP4 video using SuperWorkspace.

## Prerequisites & Entry Point

SuperWorkspace runs a private local Unix-domain socket server (`control.sock`) while the app is open. All screen capture and accessibility permissions are owned by `SuperWorkspace.app`, so the calling terminal or agent does not need separate macOS privacy permissions.

Use the CLI wrapper if installed in `PATH`, or invoke the app binary directly:

```bash
CLI="superworkspace"
command -v superworkspace >/dev/null 2>&1 || CLI="/Applications/SuperWorkspace.app/Contents/MacOS/SuperWorkspace cli"
```

Every command outputs JSON: `{"ok": true, "data": ...}` or `{"ok": false, "error": "..."}`.

## Standard Workflow

1. **Check status and permissions first**
   ```bash
   $CLI status
   ```
   Verify `hasScreenRecordingPermission: true` and `hasAccessibilityPermission: true`. If either is `false`, stop and ask the user to grant the missing permission to `/Applications/SuperWorkspace.app` in macOS System Settings.

2. **Inspect windows and capture a screenshot before clicking**
   Never guess UI coordinates blindly. List visible app windows and take a screenshot first:
   ```bash
   $CLI windows
   $CLI screenshot --out /tmp/sw-before.png
   # Or capture a single app window (returns screen origin x, y, width, height):
   $CLI screenshot --app Safari --out /tmp/sw-window.png
   ```
   Read the screenshot image to determine exact screen coordinates `(x, y)` in display points (`width × height` returned by `screenshot`).

3. **Optionally resize and position the target window**
   ```bash
   $CLI resize --window <windowID> --width 1440 --height 900 --x 36 --y 40
   ```

4. **Start headless recording**
   - Single app window (clean frame, excludes Dock/menu bar):
     ```bash
     $CLI record start --app <AppName> --system-audio off --project "<ProjectName>"
     ```
   - Or full display (captures Dock, menu bar, and multi-window popups/dropdowns):
     ```bash
     $CLI record start --display --system-audio off --project "<ProjectName>"
     ```
   - Set `--system-audio on` when recording audio-producing demos; `--fps 60` is the default.

5. **Perform smooth, human-paced GUI actions**
   All input actions are dispatched by the authorized `SuperWorkspace.app` process:
   ```bash
   # Smooth pointer movement
   $CLI input move --x 720 --y 450 --duration 0.4

   # Smooth move + left click (triggers Auto-Zoom in styled rough cut)
   $CLI input click --x 168 --y 65

   # Character-by-character hardware-keycode typing (automatically switches to ASCII IME for pure ASCII)
   $CLI input type --text "whoami" --interval 0.14

   # Clipboard paste (use for CJK / multi-line text)
   $CLI input paste --text "你好"

   # Key press with optional modifiers (--cmd, --shift)
   $CLI input key --code 36            # Return
   $CLI input key --code 17 --cmd      # Cmd+T
   $CLI input key --code 45 --cmd      # Cmd+N
   $CLI input key --code 13 --cmd      # Cmd+W
   $CLI input key --code 53            # Escape

   # Smooth mouse drag (e.g. selecting text output)
   $CLI input drag --from-x 4 --from-y 162 --to-x 160 --to-y 162 --duration 0.55
   ```

6. **Stop recording and render styled rough cut**
   ```bash
   # Styled rough cut (default): applies wallpaper, rounded corners, shadow, smooth vector cursor, and Auto-Zoom at 60fps
   $CLI record stop --styled

   # Fast raw capture without rough-cut styling:
   $CLI record stop --raw

   # Save the recorded demo directly into the project's media library (for AI Packaging to reference):
   $CLI record stop --styled --library --name "settings-demo"

   # Optional: mark the recorded video as ready for AI Packaging (manually started from workspace)
   $CLI record stop --styled --package --prompt "Highlight key workflow steps"
   ```

7. **Inspect project state and export final MP4**
   ```bash
   $CLI project
   $CLI export --subtitles off
   # Or wait for transcriptState == "complete" and export with embedded captions + SRT:
   $CLI export --subtitles on --srt
   ```

## Common macOS Virtual Key Codes

| Key | Code | Key | Code |
| --- | --- | --- | --- |
| Return | `36` | Escape | `53` |
| Tab | `48` | Space | `49` |
| Delete / Backspace | `51` | Up / Down | `126` / `125` |
| Left / Right | `123` / `124` | `F` (Cmd+F) | `3` |
| `T` (Cmd+T) | `17` | `N` (Cmd+N) | `45` |
| `W` (Cmd+W) | `13` | `K` (Cmd+K) | `40` |

## Practical Guidelines

- **Always verify visually**: After `record stop --styled`, inspect a frame or take a screenshot to verify the target UI actually responded as intended before delivering the video.
- **Avoid unintended side effects**: Before clicking inside messaging, email, or production apps, verify the target conversation/account via `screenshot` so no message is sent to the wrong recipient.
- **Timing**: Wait briefly (`0.5s–2.0s`) after opening a new window or terminal tab so animations and shell prompts finish rendering before typing.
- **Keep demos clean**: Prefer a fresh tab/window and pause `1.5s` at the end of the final action so viewers can read the outcome before the video ends.
