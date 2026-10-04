#!/bin/zsh
# Builds Nook and installs it to /Applications, so Spotlight, Tinycast and Finder can launch it.
# Opening Nook again while it runs opens the notch panel. Pass --hermes to also copy the Hermes plugin.
set -euo pipefail
cd "${0:A:h}"
./build.sh
dest=/Applications
[[ -w $dest ]] || dest=~/Applications
mkdir -p $dest
pkill -x Nook 2>/dev/null || true
sleep 0.3
rm -rf $dest/Nook.app
cp -R build.noindex/Nook.app $dest/
# Index it right away instead of waiting for Spotlight/LaunchServices to notice.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f $dest/Nook.app
mdimport $dest/Nook.app 2>/dev/null || true
if [[ "${1:-}" == "--hermes" ]]; then
  mkdir -p ~/.hermes/plugins
  rm -rf ~/.hermes/plugins/nook
  cp -R hermes-plugin/nook ~/.hermes/plugins/
  echo "Hermes plugin copied. Run: hermes plugins enable nook  (then restart Hermes)"
fi
open $dest/Nook.app
echo "Nook installed in $dest"
