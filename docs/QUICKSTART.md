# SuperWorkspace quick start

## Install

1. Download the `macos-arm64.dmg` installer from [GitHub Releases](https://github.com/FlashingChen/SuperWorkspace/releases). This build is for Apple Silicon Macs running macOS 14 or later.
2. Open the DMG, drag **SuperWorkspace.app** to **Applications**, then eject the disk image. A ZIP download is also available. The release is ad-hoc signed and unnotarized. If macOS blocks it, review [Apple’s guidance for opening an app you trust](https://support.apple.com/en-us/102445).
3. On the first recording, grant screen recording and accessibility access when prompted. Grant microphone or camera access if you use those inputs. Follow any macOS prompt to reopen the app.

Pi, Node.js, FFmpeg, whisper.cpp, and the default multilingual speech model are included. You can record, transcribe, edit, and export without an AI account.

## Connect a model

Open **设置 → AI 动效 → 内置 Pi**. Enter your provider’s OpenAI-compatible API base URL, model ID, and API key. Select **测试连接**, then **保存**. The key is stored in macOS Keychain.

AI motion requires a model that supports tool calling. Turn on **模型支持图片** when your model accepts image input. The first AI motion job downloads Remotion and its browser automatically, so keep the app online while it prepares them.

## Make a first video

1. Click **新建项目** and name your project.
2. Click **录制新素材**. In the compact recorder, choose what to capture and check the microphone before recording a short clip.
3. Stop the recording, trim it in the recorder, and click **完成录制**. Enable **添加 AI 动效** if you connected a model and want motion on this clip.
4. In **拼装**, play the timeline and review the generated subtitles. Click a subtitle to edit its text. To change clip order, drag the video clips along the timeline.
5. Click **导出成片**, choose the aspect ratio and subtitle options, then export the MP4.

If a background task fails, click the status icon on the material card to see the details. Retry from its **⋯** menu. The original clip is available while AI motion runs.
