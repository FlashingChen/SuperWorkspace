# Third-party notices

## DogSC

录制与粗剪组件来自 [DogSC](https://github.com/laogou717/dogsc)，采用 MIT License。固定版本由 `scripts/fetch-recorder.py` 声明；源码在构建时获取，不包含在本仓库历史中。

适配层移除独立应用生命周期与更新实现，并接入宿主的素材导出流程。构建将上游完整、未改写的许可证复制为应用资源中的 `Recorder-LICENSE`。本仓库的 MIT License 不替代上游归属声明。

## 录制界面字体

上游提供的 Alibaba PuHuiTi 3.0 字体随录制界面资源一起打包。字体使用上游 `Resources/Fonts/LICENSE.txt` 中的独立法律声明，并非本仓库 MIT License 的一部分。构建保留该完整声明，不修改字体文件。

## 内置 Pi

- [Pi](https://github.com/earendil-works/pi) SDK 采用 MIT License，固定依赖见 `Integration/PiRuntime/package-lock.json`。应用携带上游许可证 `PiRuntime/Pi-LICENSE` 和 npm 依赖附带的许可证。
- [Node.js](https://nodejs.org/) 和随其发行的 npm 来自官方发行包，版本和校验值由 `scripts/prepare-pi.py` 固定。应用携带发行包附带的许可证。

## 本地媒体工具

- [FFmpeg](https://ffmpeg.org/) 和 FFprobe 以独立命令行程序运行。应用包含 LGPL 2.1 许可证。每个包含 FFmpeg 的 [GitHub Release](https://github.com/FlashingChen/SuperWorkspace/releases) 同时提供对应源码和构建参数。
- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) 与 [Whisper Base](https://github.com/openai/whisper) 用于本地字幕识别。应用保留两者的 MIT 许可证。
- [Remotion](https://github.com/remotion-dev/remotion) 及其浏览器在首次动效任务中安装，适用各自的许可证与服务条款。
