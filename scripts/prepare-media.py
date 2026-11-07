#!/usr/bin/env python3
"""Build the pinned media tools and stage the default speech model."""
import hashlib
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / ".build"
DOWNLOADS = BUILD / "MediaDownloads"
RUNTIME = BUILD / "MediaRuntime"
FFMPEG = (
    "ffmpeg-8.0.1.tar.gz",
    "https://github.com/FFmpeg/FFmpeg/archive/894da5ca7d742e4429ffb2af534fcda0103ef593.tar.gz",
    "9dad3557314f1b7923b61aff15e30079e964c3b41276bbd43dd8bb15b8028b5f",
)
WHISPER = (
    "whisper-1.8.4.tar.gz",
    "https://github.com/ggml-org/whisper.cpp/archive/9386f239401074690479731c1e41683fbbeac557.tar.gz",
    "0cc49e22729edd3cd2e7727522b456f459e1860fe65e975b39ce1a194857f9d5",
)
MODEL = (
    "ggml-base.bin",
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base.bin",
    "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe",
)
MODEL_LICENSE = (
    "Whisper-model-LICENSE",
    "https://github.com/openai/whisper/raw/v20250625/LICENSE",
    "b5d65a59060e68c4ff940e1eddfa6f94b2d68fdf58ed7f4dd57721c997e35e9d",
)
FFMPEG_SOURCE = BUILD / "ffmpeg-8.0.1-source.tar.gz"
FFMPEG_FLAGS = [
    "--disable-autodetect", "--disable-gpl", "--disable-nonfree", "--disable-doc",
    "--disable-debug", "--disable-x86asm", "--disable-network", "--disable-ffplay",
    "--enable-videotoolbox", "--enable-audiotoolbox",
]


def checksum(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fetch(spec, stage):
    name, url, expected = spec
    destination = DOWNLOADS / name
    if destination.is_file() and checksum(destination) == expected:
        return destination
    temporary = stage / name
    subprocess.run(["curl", "--fail", "--silent", "--show-error", "--location",
                    "--connect-timeout", "15", "--max-time", "600", "--retry", "2",
                    "--output", temporary, url], check=True)
    if checksum(temporary) != expected:
        raise SystemExit(f"Checksum did not match for {name}.")
    temporary.replace(destination)
    return destination


def extract(archive, destination):
    destination.mkdir()
    subprocess.run(["tar", "-xzf", archive, "--strip-components", "1", "-C", destination], check=True)


def main():
    DOWNLOADS.mkdir(parents=True, exist_ok=True)
    stamp = hashlib.sha256(Path(__file__).read_bytes() + platform.machine().encode()).hexdigest()
    stamp_file = RUNTIME / "stamp"
    if stamp_file.is_file() and stamp_file.read_text() == stamp and FFMPEG_SOURCE.is_file():
        return
    jobs = str(min(os.cpu_count() or 1, 8))
    environment = dict(os.environ, MACOSX_DEPLOYMENT_TARGET="14.0")

    with tempfile.TemporaryDirectory(prefix="media-stage-", dir=BUILD) as temporary:
        stage = Path(temporary)
        ffmpeg, whisper, model, model_license = (fetch(spec, stage) for spec in (FFMPEG, WHISPER, MODEL, MODEL_LICENSE))
        ffmpeg_source = stage / "ffmpeg-8.0.1"
        whisper_source = stage / "whisper"
        extract(ffmpeg, ffmpeg_source)
        extract(whisper, whisper_source)
        recipe = "MACOSX_DEPLOYMENT_TARGET=14.0 ./configure " + " ".join(FFMPEG_FLAGS) + "\nmake\n"
        (ffmpeg_source / "SUPERWORKSPACE-BUILD.txt").write_text(recipe)
        source_archive = stage / FFMPEG_SOURCE.name
        subprocess.run(["tar", "-czf", source_archive, "-C", stage, ffmpeg_source.name], check=True)

        subprocess.run(["./configure", *FFMPEG_FLAGS], cwd=ffmpeg_source, env=environment, check=True)
        subprocess.run(["make", "-j", jobs, "ffmpeg", "ffprobe"], cwd=ffmpeg_source, env=environment, check=True)
        whisper_build = stage / "whisper-build"
        subprocess.run(["cmake", "-S", whisper_source, "-B", whisper_build,
                        "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0",
                        "-DBUILD_SHARED_LIBS=OFF", "-DGGML_NATIVE=OFF", "-DGGML_METAL=OFF",
                        "-DWHISPER_BUILD_TESTS=OFF", "-DWHISPER_BUILD_SERVER=OFF"], check=True)
        subprocess.run(["cmake", "--build", whisper_build, "--target", "whisper-cli", "--parallel", jobs], check=True)

        runtime = stage / "runtime"
        binaries = runtime / "bin"
        binaries.mkdir(parents=True)
        for executable in ("ffmpeg", "ffprobe"):
            shutil.copy2(ffmpeg_source / executable, binaries / executable)
        shutil.copy2(whisper_build / "bin" / "whisper-cli", binaries)
        shutil.copy2(model, runtime)
        shutil.copy2(model_license, runtime)
        shutil.copy2(ffmpeg_source / "COPYING.LGPLv2.1", runtime / "FFmpeg-LICENSE")
        shutil.copy2(whisper_source / "LICENSE", runtime / "Whisper-cpp-LICENSE")
        (runtime / "FFmpeg-Build.txt").write_text(recipe)
        (runtime / "stamp").write_text(stamp)
        shutil.rmtree(RUNTIME, ignore_errors=True)
        runtime.rename(RUNTIME)
        source_archive.replace(FFMPEG_SOURCE)
    print("Prepared bundled FFmpeg, whisper.cpp, and Whisper Base.")


if __name__ == "__main__":
    main()
