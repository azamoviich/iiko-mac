#!/bin/zsh
# iiko-mac — удаляет всё, что создал установщик.
ROOT="${IIKO_MAC_ROOT:-$HOME/iiko-mac}"
APPS_DIR="${IIKO_MAC_APPS:-$HOME/Applications}"

print "Будет удалено:"
print "  $ROOT"
print "  $APPS_DIR/iikoOffice.app"
print "  $APPS_DIR/iikoChain.app"
read "ok?Продолжить? [y/N]: " </dev/tty
[[ "$ok" == [yYдД]* ]] || { print "Отменено."; exit 0; }

[[ -x "$ROOT/Wine Staging.app/Contents/Resources/wine/bin/wineserver" ]] && \
  WINEPREFIX="$ROOT/prefix" "$ROOT/Wine Staging.app/Contents/Resources/wine/bin/wineserver" -k 2>/dev/null
rm -rf "$ROOT" "$APPS_DIR/iikoOffice.app" "$APPS_DIR/iikoChain.app"
print "Удалено."
