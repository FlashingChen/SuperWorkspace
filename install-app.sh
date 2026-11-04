#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
./build-app.sh "${1:-debug}"
installed_app="$HOME/Applications/SuperWorkspace.app"
mkdir -p "$HOME/Applications"
if [[ -e "$installed_app" ]]; then
  installed_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$installed_app/Contents/Info.plist")
  [[ "$installed_id" == "com.superworkspace.app" ]] || { echo 'The destination contains a different app.' >&2; exit 1; }
fi
ditto .build/app/SuperWorkspace.app "$installed_app"
[[ -x "$installed_app/Contents/MacOS/SuperWorkspace" ]] || { echo 'Application copy failed.' >&2; exit 1; }
codesign --verify --deep --strict "$installed_app"
touch "$installed_app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$installed_app"
python3 - "$installed_app" <<'PY'
from pathlib import Path
import sys
app = Path(sys.argv[1])
launcher = Path.home() / 'Desktop' / 'SuperWorkspace.app'
if launcher.is_symlink():
    expected = Path.cwd() / '.build/app/SuperWorkspace.app'
    if launcher.resolve() not in (app.resolve(), expected.resolve()):
        raise SystemExit('Desktop launcher points to a different app; left unchanged.')
    launcher.unlink()
elif launcher.exists():
    raise SystemExit('Desktop launcher is not a symbolic link; left unchanged.')
launcher.symlink_to(app, target_is_directory=True)
PY
open "$installed_app"
