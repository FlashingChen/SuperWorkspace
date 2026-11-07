#!/usr/bin/env python3
"""Stage the pinned Node and Pi SDK for the app bundle."""
import hashlib
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
MANIFESTS = ROOT / "Integration" / "PiRuntime"
BUILD = ROOT / ".build"
TARGET = BUILD / "PiRuntime"
NODE_VERSION = "24.22.2"
NODE_HASHES = {
    "arm64": "aa9549349e47dffaa42dcf95d6e06ade8c4bdafc980979883b88767670df385a",
    "x64": "d5e336d588c45be0c37dbd52cc29895593009ca4997a77a1fd02815131ed0e52",
}
PI_LICENSE = "https://github.com/earendil-works/pi/raw/4a080252f06caf63a525d7873c5d94d3c23887e0/LICENSE"
PI_LICENSE_HASH = "0457f5bcec3b3b211605dfb5d1a49042fd638f3686a410fe099c24a25af13c48"


def download(url, target, expected_hash):
    subprocess.run(["curl", "--fail", "--silent", "--show-error", "--location",
                    "--retry", "2", "--output", target, url], check=True)
    digest = hashlib.sha256()
    with target.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != expected_hash:
        raise SystemExit("Runtime download checksum did not match.")


def main():
    architecture = {"arm64": "arm64", "x86_64": "x64"}.get(platform.machine())
    if not architecture:
        raise SystemExit("Unsupported Pi runtime architecture.")
    stamp = hashlib.sha256(
        (MANIFESTS / "package-lock.json").read_bytes()
        + NODE_HASHES[architecture].encode() + PI_LICENSE_HASH.encode() + Path(__file__).read_bytes()
    ).hexdigest()
    stamp_file = BUILD / "PiRuntime.stamp"
    if stamp_file.is_file() and stamp_file.read_text() == stamp and TARGET.is_dir():
        return

    BUILD.mkdir(exist_ok=True)
    name = f"node-v{NODE_VERSION}-darwin-{architecture}"
    with tempfile.TemporaryDirectory(prefix="pi-stage-", dir=BUILD) as temporary:
        stage = Path(temporary)
        archive = stage / f"{name}.tar.gz"
        download(f"https://nodejs.org/dist/v{NODE_VERSION}/{archive.name}", archive, NODE_HASHES[architecture])
        subprocess.run(["tar", "-xzf", archive, "-C", stage], check=True)
        runtime = stage / "runtime"
        runtime.mkdir()
        node = runtime / "node"
        (stage / name).rename(node)
        shutil.rmtree(node / "include")
        for filename in ("package.json", "package-lock.json"):
            shutil.copyfile(MANIFESTS / filename, runtime / filename)
        subprocess.run([node / "bin" / "node", node / "lib" / "node_modules" / "npm" / "bin" / "npm-cli.js",
                        "ci", "--omit=dev", "--ignore-scripts", "--no-audit", "--no-fund"],
                       cwd=runtime, check=True)
        download(PI_LICENSE, runtime / "Pi-LICENSE", PI_LICENSE_HASH)
        shutil.rmtree(TARGET, ignore_errors=True)
        runtime.rename(TARGET)
        stamp_file.write_text(stamp)
    print("Prepared bundled Pi and Node runtime.")


if __name__ == "__main__":
    main()
