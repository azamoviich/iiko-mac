#!/bin/zsh
# iiko-mac — remove everything the installer created.
ROOT="${IIKO_MAC_ROOT:-$HOME/iiko-mac}"
APPS_DIR="${IIKO_MAC_APPS:-$HOME/Applications}"

print "This deletes:"
print "  $ROOT"
print "  $APPS_DIR/iikoOffice.app"
print "  $APPS_DIR/iikoChain.app"
read "ok?Continue? [y/N]: " </dev/tty
[[ "$ok" == [yY]* ]] || { print "Cancelled."; exit 0; }

[[ -x "$ROOT/Wine Staging.app/Contents/Resources/wine/bin/wineserver" ]] && \
  WINEPREFIX="$ROOT/prefix" "$ROOT/Wine Staging.app/Contents/Resources/wine/bin/wineserver" -k 2>/dev/null
rm -rf "$ROOT" "$APPS_DIR/iikoOffice.app" "$APPS_DIR/iikoChain.app"
print "Removed."
