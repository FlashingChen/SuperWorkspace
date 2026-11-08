#!/usr/bin/env python3
"""Package a signed application into a compressed drag-to-install disk image."""

import argparse
import pathlib
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    args = parser.parse_args()
    app = args.app.resolve()
    output = args.output.resolve()
    if not (app / "Contents/Info.plist").is_file():
        parser.error("Expected an application bundle with Contents/Info.plist.")
    if output.suffix != ".dmg" or output.exists():
        parser.error("Output must be a new .dmg file.")

    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="superworkspace-dmg-") as temporary:
        staging = pathlib.Path(temporary)
        subprocess.run(["ditto", str(app), str(staging / "SuperWorkspace.app")], check=True)
        (staging / "Applications").symlink_to("/Applications")
        subprocess.run([
            "hdiutil", "create", "-volname", "SuperWorkspace", "-fs", "HFS+",
            "-format", "UDZO", "-srcfolder", str(staging), str(output),
        ], check=True)
    subprocess.run(["hdiutil", "verify", str(output)], check=True)


if __name__ == "__main__":
    main()
