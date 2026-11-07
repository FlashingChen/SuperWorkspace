# Third-party notices

## DogSC

录制与粗剪组件来自 [DogSC](https://github.com/laogou717/dogsc)，采用 MIT License。固定版本由 `scripts/fetch-recorder.py` 声明；源码在构建时获取，不包含在本仓库历史中。

适配层移除独立应用生命周期与更新实现，并接入宿主的素材导出流程。构建将上游完整、未改写的许可证复制为应用资源中的 `Recorder-LICENSE`。本仓库的 MIT License 不替代上游归属声明。

## 录制界面字体

上游提供的 Alibaba PuHuiTi 3.0 字体随录制界面资源一起打包。字体使用上游 `Resources/Fonts/LICENSE.txt` 中的独立法律声明，并非本仓库 MIT License 的一部分。构建保留该完整声明，不修改字体文件。

## 内置 Pi

- [Pi](https://github.com/earendil-works/pi) SDK 采用 MIT License，固定依赖见 `Integration/PiRuntime/package-lock.json`。应用携带上游许可证 `PiRuntime/Pi-LICENSE` 和 npm 依赖附带的许可证。
- [Node.js](https://nodejs.org/) 和随其发行的 npm 来自官方发行包，版本和校验值由 `scripts/prepare-pi.py` 固定。应用携带发行包附带的许可证。

## 另行安装的工具

- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) 用于本地字幕识别。
- [FFmpeg](https://ffmpeg.org/) 用于字幕任务的音频提取。
- [Remotion](https://github.com/remotion-dev/remotion) 用于外部执行器生成动效。

这些工具、模型及外部 AI 执行器不随本仓库分发，各自适用其许可证与服务条款。
