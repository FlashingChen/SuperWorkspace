# Third-party notices

## DogSC

同进程录制与单段粗剪引擎（`Sources/RecorderCore`、`Sources/RecorderKit`）基于 [DogSC](https://github.com/laogou717/dogsc) 的 MIT License 核心收编并精简，移除了独立应用生命周期、更新器、独立设置窗与冗余界面，并接入宿主的共享主题与导出流程。

上游完整、未改写的 MIT 许可证保留于 `Resources/Recorder-LICENSE`，并在打包时复制到应用资源目录。本仓库的 MIT License 不替代上游归属声明。录制界面已改用 macOS 系统字体，不再携带第三方字体文件。

## 内置 Pi

- [Pi](https://github.com/earendil-works/pi) SDK 采用 MIT License，固定依赖见 `Integration/PiRuntime/package-lock.json`。应用携带上游许可证 `PiRuntime/Pi-LICENSE` 和 npm 依赖附带的许可证。
- [pi-web-access](https://github.com/nicobailon/pi-web-access) 提供字幕校正的联网查证工具，采用 MIT License，随 npm 依赖打包并保留其许可证。
- [Node.js](https://nodejs.org/) 和随其发行的 npm 来自官方发行包，版本和校验值由 `scripts/prepare-pi.py` 固定。应用携带发行包附带的许可证。

## 本地媒体工具

- [FFmpeg](https://ffmpeg.org/) 和 FFprobe 以独立命令行程序运行。应用包含 LGPL 2.1 许可证。每个包含 FFmpeg 的 [GitHub Release](https://github.com/FlashingChen/SuperWorkspace/releases) 同时提供对应源码和构建参数。
- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) 与 [Whisper Base](https://github.com/openai/whisper) 用于本地字幕识别。应用保留两者的 MIT 许可证。
- [Remotion](https://github.com/remotion-dev/remotion) 及其浏览器在首次动效任务中安装，适用各自的许可证与服务条款。
