"""Check the packaged media tools without a user's PATH or model settings."""
from pathlib import Path
import subprocess
import sys
import tempfile


def main(runtime):
    runtime = runtime.resolve()
    binaries = runtime / "bin"
    model = runtime / "ggml-base.bin"
    environment = {"PATH": str(binaries) + ":/usr/bin:/bin"}
    version = subprocess.check_output([binaries / "ffmpeg", "-version"], env=environment, text=True)
    assert version.startswith("ffmpeg version 8.0.1 "), version.splitlines()[0]
    with tempfile.TemporaryDirectory() as temporary:
        audio = Path(temporary) / "audio.wav"
        subprocess.run([binaries / "ffmpeg", "-v", "error", "-f", "lavfi",
                        "-i", "anullsrc=r=16000:cl=mono", "-t", "1", audio],
                       env=environment, check=True)
        probe = subprocess.check_output([binaries / "ffprobe", "-v", "error",
                                         "-show_entries", "stream=sample_rate",
                                         "-of", "default=nw=1:nk=1", audio],
                                        env=environment, text=True)
        assert probe.strip() == "16000", probe
        subprocess.run([binaries / "whisper-cli", "-m", model, "-f", audio, "-l", "en", "-nt"],
                       env=environment, check=True, capture_output=True, timeout=30)
    print("Packaged FFmpeg, FFprobe, whisper.cpp, and the default model passed.")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
