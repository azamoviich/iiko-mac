#!/bin/zsh
# iiko-mac — run the original iikoOffice / iikoChain BackOffice on macOS
# through Wine. No virtual machine.
#
#   zsh -c "$(curl -fsSL https://raw.githubusercontent.com/azamoviich/iiko-mac/main/install.sh)"
#   ./install.sh 9.2.7014.0 office|chain|both
#
# This script ships NO iiko or Microsoft files: everything is downloaded on
# your Mac from the vendors' own servers (WineHQ build, microsoft.com,
# downloads.iiko.online). You need your own iiko licence/server to log in.
#
# Not affiliated with or endorsed by iiko.

set -e
setopt null_glob

ROOT="${IIKO_MAC_ROOT:-$HOME/iiko-mac}"
APPS_DIR="${IIKO_MAC_APPS:-$HOME/Applications}"
CACHE="${IIKO_MAC_CACHE:-$ROOT/cache}"
WINE_VER="11.18"
WINE_URL="https://github.com/Gcenx/macOS_Wine_builds/releases/download/$WINE_VER/wine-staging-$WINE_VER-osx64.tar.xz"
NET48_URL="https://download.visualstudio.microsoft.com/download/pr/7afca223-55d2-470a-8edc-6a1739ae3252/abd170b4b0ec15ad0222a809b761a036/ndp48-x86-x64-allos-enu.exe"
NET40_URL="https://download.microsoft.com/download/9/5/A/95A9616B-7A37-4AF6-BC36-D6EA96C8DAAE/dotNetFx40_Full_x86_x64.exe"
IIKO_BASE="https://downloads.iiko.online"

say()  { print -P "%F{cyan}==>%f $*"; }
fail() { print -P "%F{red}ERROR:%f $*" >&2; exit 1; }

fetch() { # url dest
  [[ -s "$2" ]] && return 0
  curl -fL --retry 3 -C - --progress-bar -o "$2.part" "$1" || fail "Download failed: $1"
  mv "$2.part" "$2"
}

# ---------------------------------------------------------------- input
VERSION="${1:-$IIKO_VERSION}"
PRODUCT="${2:-$IIKO_PRODUCT}"

print
print "iiko for Mac installer"
print "----------------------"
if [[ -z "$VERSION" ]]; then
  print "Your BackOffice version must match your iiko server exactly."
  print "Example: 9.2.7014.0"
  read "VERSION?iiko version: " </dev/tty
fi
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' ]] || fail "Version must look like 9.2.7014.0"

if [[ -z "$PRODUCT" ]]; then
  print "What to install?  1) iikoOffice   2) iikoChain   3) both"
  read "choice?Choice [1]: " </dev/tty
  case "${choice:-1}" in
    1) PRODUCT=office ;; 2) PRODUCT=chain ;; 3) PRODUCT=both ;;
    *) fail "Unknown choice" ;;
  esac
fi
case "$PRODUCT" in
  office) PRODUCTS=(RMS) ;; chain) PRODUCTS=(Chain) ;; both) PRODUCTS=(RMS Chain) ;;
  *) fail "Product must be office, chain or both" ;;
esac

for p in $PRODUCTS; do
  curl -fsIL -m 30 -o /dev/null "$IIKO_BASE/$VERSION/iiko/$p/BackOffice/Setup.$p.BackOffice.exe" \
    || fail "iiko $p BackOffice $VERSION was not found on $IIKO_BASE — check the version number."
done

mkdir -p "$ROOT" "$CACHE" "$APPS_DIR"

# ---------------------------------------------------------------- rosetta
if [[ "$(uname -m)" == "arm64" ]] && ! arch -x86_64 /usr/bin/true 2>/dev/null; then
  say "Installing Rosetta 2 (Apple's Intel translator)"
  softwareupdate --install-rosetta --agree-to-license || fail "Rosetta install failed"
fi

# ---------------------------------------------------------------- wine
WINE_APP="$ROOT/Wine Staging.app"
if [[ ! -x "$WINE_APP/Contents/Resources/wine/bin/wine" ]]; then
  say "Downloading Wine $WINE_VER"
  fetch "$WINE_URL" "$CACHE/wine.tar.xz"
  tar -xf "$CACHE/wine.tar.xz" -C "$ROOT"
  xattr -drs com.apple.quarantine "$WINE_APP" 2>/dev/null || true
fi
export PATH="$WINE_APP/Contents/Resources/wine/bin:$PATH"
export WINEPREFIX="$ROOT/prefix"
export WINEDEBUG=-all MVK_CONFIG_LOG_LEVEL=0
wine --version >/dev/null || fail "Wine does not start"

SYS="$WINEPREFIX/drive_c/windows"
NETDIR="$SYS/Microsoft.NET/Framework64/v4.0.30319"

# ---------------------------------------------------------------- .NET 4.8
if [[ ! -f "$NETDIR/clr.dll" ]]; then
  say "Creating Windows environment"
  wineboot -i >/dev/null 2>&1; wineserver -w
  wine winecfg -v win7 >/dev/null 2>&1

  say "Installing Microsoft .NET Framework 4.8 (takes a few minutes)"
  fetch "$NET48_URL" "$CACHE/ndp48.exe"
  WINEDLLOVERRIDES="mscoree=n,b;fusion=b" wine "$CACHE/ndp48.exe" /q /norestart >/dev/null 2>&1 || true
  wineserver -w
  [[ -f "$NETDIR/clr.dll" ]] || fail ".NET Framework 4.8 did not install"
fi

# The 4.8 installer skips mscoree.dll on Windows 7+, so Wine keeps routing
# managed apps to Mono. Take Microsoft's loader from the 4.0 package instead.
if ! grep -qa "Microsoft Corporation" "$SYS/system32/mscoree.dll" 2>/dev/null \
   || grep -qa "Wine builtin DLL" "$SYS/system32/mscoree.dll"; then
  say "Installing the .NET runtime loader"
  fetch "$NET40_URL" "$CACHE/dotNetFx40.exe"
  N40="$CACHE/net40"; rm -rf "$N40"; mkdir -p "$N40"
  WINEDLLOVERRIDES="mscoree=b" wine "$CACHE/dotNetFx40.exe" /q "/x:$(winepath -w "$N40")" >/dev/null 2>&1 || true
  wineserver -w
  wine extrac32 /Y /E /L "$(winepath -w "$N40/out")" "$(winepath -w "$N40/netfx_Core.mzz")" >/dev/null 2>&1 || true
  wineserver -w
  [[ -f "$N40/out/_003_mscoree_dll_amd64" ]] || fail "Could not unpack mscoree.dll"
  cp "$N40/out/_003_mscoree_dll_amd64" "$SYS/system32/mscoree.dll"
  cp "$N40/out/_003_mscoree_dll_x86"   "$SYS/syswow64/mscoree.dll"
  rm -rf "$N40"
fi
export WINEDLLOVERRIDES="mscoree=n"

# ---------------------------------------------------------------- tweaks
say "Applying Mac integration settings"
wine reg add 'HKCU\Software\Wine\DllOverrides' /v mscoree /d native /f >/dev/null 2>&1
# Cmd+C / Cmd+V etc. behave like Ctrl
for k in LeftCommandIsCtrl RightCommandIsCtrl; do
  wine reg add 'HKCU\Software\Wine\Mac Driver' /v $k /d y /f >/dev/null 2>&1
done
# Exported files open in the Mac's default app (Excel, Numbers, Preview...)
wine reg add 'HKCR\MacOpen\shell\open\command' /ve /d '"C:\windows\system32\winebrowser.exe" "%1"' /f >/dev/null 2>&1
for e in xlsx xls xlsm csv pdf doc docx rtf png jpg jpeg zip; do
  wine reg add "HKCR\\.$e" /ve /d MacOpen /f >/dev/null 2>&1
done

# ---------------------------------------------------------------- iiko
make_app() { # name exe_dir
  local app="$APPS_DIR/$1.app"
  rm -rf "$app"; mkdir -p "$app/Contents/MacOS"
  cat > "$app/Contents/MacOS/run" <<EOF
#!/bin/zsh
export PATH="$WINE_APP/Contents/Resources/wine/bin:\$PATH"
export WINEPREFIX="$WINEPREFIX" WINEDLLOVERRIDES="mscoree=n" WINEDEBUG=-all MVK_CONFIG_LOG_LEVEL=0
cd "$2" && exec wine BackOffice.exe
EOF
  chmod +x "$app/Contents/MacOS/run"
  cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$1</string>
  <key>CFBundleIdentifier</key><string>local.iiko-mac.$1</string>
  <key>CFBundleExecutable</key><string>run</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
</dict></plist>
EOF
}

for p in $PRODUCTS; do
  [[ $p == RMS ]] && name=iikoOffice || name=iikoChain
  dest="$ROOT/apps/$name-$VERSION"
  exe=$(find "$dest" -name BackOffice.exe -not -path "*/Cef/*" 2>/dev/null | head -1)
  if [[ -z "$exe" ]]; then
    say "Downloading $name $VERSION from iiko (about 500 MB)"
    setup="$CACHE/Setup.$p.$VERSION.exe"
    fetch "$IIKO_BASE/$VERSION/iiko/$p/BackOffice/Setup.$p.BackOffice.exe" "$setup"

    say "Unpacking $name"
    # The setup is a WiX bundle: a PE stub followed by two cabinets (the
    # manifest/UI cab, then the payload cab). Carve both out by their headers.
    layout="$CACHE/layout-$p"; rm -rf "$layout" "$dest"
    mkdir -p "$layout/ux" "$layout/pl" "$layout/msi" "$dest"
    cabs=()
    for off in $(grep -abo "MSCF" "$setup" | head -20 | cut -d: -f1); do
      size=$(tail -c +$((off + 9)) "$setup" | head -c 4 | od -An -tu4 | tr -d ' ')
      (( size > 100000 )) && cabs+=("$off:$size")
      (( $#cabs == 2 )) && break
    done
    (( $#cabs == 2 )) || fail "Unexpected $name installer layout"
    tail -c +$(( ${cabs[1]%%:*} + 1 )) "$setup" | head -c ${cabs[1]##*:} > "$layout/ux.cab"
    tail -c +$(( ${cabs[2]%%:*} + 1 )) "$setup" | head -c ${cabs[2]##*:} > "$layout/pl.cab"
    rm -f "$setup"
    wine extrac32 /Y /E /L "$(winepath -w "$layout/ux")" "$(winepath -w "$layout/ux.cab")" >/dev/null 2>&1 || true
    wine extrac32 /Y /E /L "$(winepath -w "$layout/pl")" "$(winepath -w "$layout/pl.cab")" >/dev/null 2>&1 || true
    wineserver -w
    rm -f "$layout/pl.cab"

    # Manifest maps payload ids (a10, a15, ...) to real file names
    payloads=$(grep -o '<Payload [^>]*>' "$layout/ux/0")
    msi_id=$(print -r -- "$payloads" | grep -E 'BackOffice\.x64\.msi"' | head -1 | sed -E 's/.*SourcePath="([^"]*)".*/\1/')
    cab_line=$(print -r -- "$payloads" | grep -E 'FilePath="packages\\BackOffice\\[^"]*\.cab"' | head -1)
    cab_id=$(print -r -- "$cab_line" | sed -E 's/.*SourcePath="([^"]*)".*/\1/')
    cab_name=$(print -r -- "$cab_line" | sed -E 's/.*FilePath="packages\\BackOffice\\([^"]*)".*/\1/')
    [[ -f "$layout/pl/$msi_id" && -f "$layout/pl/$cab_id" ]] || fail "Could not unpack the $name installer"
    mv "$layout/pl/$msi_id" "$layout/msi/app.msi"
    mv "$layout/pl/$cab_id" "$layout/msi/$cab_name"
    rm -rf "$layout/pl"

    wine msiexec /a "$(winepath -w "$layout/msi/app.msi")" /qn TARGETDIR="$(winepath -w "$dest")" >/dev/null 2>&1 || true
    wineserver -w
    exe=$(find "$dest" -name BackOffice.exe -not -path "*/Cef/*" | head -1)
    [[ -n "$exe" ]] || fail "Could not extract $name"
    rm -rf "$layout"
  fi
  make_app "$name" "${exe:h}"
  say "$name installed -> $APPS_DIR/$name.app"
done

rm -rf "$CACHE"/wine.tar.xz "$CACHE"/ndp48.exe "$CACHE"/dotNetFx40.exe
rmdir "$CACHE" 2>/dev/null || true

print
say "Done. Open $APPS_DIR and start iikoOffice / iikoChain."
print "    In the login window press 'Дополнительно >>' and enter your server."
