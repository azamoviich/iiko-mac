#!/bin/zsh
# iiko-mac — запуск оригинального iikoOffice / iikoChain BackOffice на macOS
# через Wine. Без виртуальной машины.
#
#   zsh -c "$(curl -fsSL https://raw.githubusercontent.com/azamoviich/iiko-mac/main/install.sh)"
#   ./install.sh 9.2.7014.0 office|chain|both
#
# В этом скрипте НЕТ файлов iiko и Microsoft: всё скачивается на ваш Mac
# с серверов самих производителей (сборка WineHQ, microsoft.com,
# downloads.iiko.online). Для входа нужны ваши лицензия и сервер iiko.
#
# Проект не связан с iiko и не одобрен ею.

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
fail() { print -P "%F{red}ОШИБКА:%f $*" >&2; exit 1; }

fetch() { # url dest
  [[ -s "$2" ]] && return 0
  curl -fL --retry 3 -C - --progress-bar -o "$2.part" "$1" || fail "Не удалось скачать: $1"
  mv "$2.part" "$2"
}

# ---------------------------------------------------------------- ввод
VERSION="${1:-$IIKO_VERSION}"
PRODUCT="${2:-$IIKO_PRODUCT}"

print
print "Установка iiko на Mac"
print "---------------------"
if [[ -z "$VERSION" ]]; then
  print "Версия BackOffice должна точно совпадать с версией вашего сервера iiko."
  print "Пример: 9.2.7014.0"
  read "VERSION?Версия iiko: " </dev/tty
fi
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' ]] || fail "Версия должна выглядеть как 9.2.7014.0"

if [[ -z "$PRODUCT" ]]; then
  print "Что установить?  1) iikoOffice   2) iikoChain   3) оба"
  read "choice?Выбор [1]: " </dev/tty
  case "${choice:-1}" in
    1) PRODUCT=office ;; 2) PRODUCT=chain ;; 3) PRODUCT=both ;;
    *) fail "Неизвестный выбор" ;;
  esac
fi
case "$PRODUCT" in
  office) PRODUCTS=(RMS) ;; chain) PRODUCTS=(Chain) ;; both) PRODUCTS=(RMS Chain) ;;
  *) fail "Продукт должен быть office, chain или both" ;;
esac

for p in $PRODUCTS; do
  curl -fsIL -m 30 -o /dev/null "$IIKO_BASE/$VERSION/iiko/$p/BackOffice/Setup.$p.BackOffice.exe" \
    || fail "iiko $p BackOffice $VERSION не найден на $IIKO_BASE — проверьте номер версии."
done

mkdir -p "$ROOT" "$CACHE" "$APPS_DIR"

# ---------------------------------------------------------------- rosetta
if [[ "$(uname -m)" == "arm64" ]] && ! arch -x86_64 /usr/bin/true 2>/dev/null; then
  say "Установка Rosetta 2 (транслятор Intel-программ от Apple)"
  softwareupdate --install-rosetta --agree-to-license || fail "Не удалось установить Rosetta"
fi

# ---------------------------------------------------------------- wine
WINE_APP="$ROOT/Wine Staging.app"
if [[ ! -x "$WINE_APP/Contents/Resources/wine/bin/wine" ]]; then
  say "Загрузка Wine $WINE_VER"
  fetch "$WINE_URL" "$CACHE/wine.tar.xz"
  tar -xf "$CACHE/wine.tar.xz" -C "$ROOT"
  xattr -drs com.apple.quarantine "$WINE_APP" 2>/dev/null || true
fi
# Ошибка Wine: в GetAdaptersAddresses размер буфера DNS не инициализирован,
# и при 4+ DNS-серверах на Mac стек переполняется — BackOffice падает в
# iphlpapi. Вставляем недостающую инициализацию (только для известной сборки).
IPHLP="$WINE_APP/Contents/Resources/wine/lib/wine/x86_64-windows/iphlpapi.dll"
if [[ -f "$IPHLP" && "$(shasum -a 256 "$IPHLP" | cut -d' ' -f1)" == "a07204d0266419dc06b78f696470d7e1eaa5fa43a7c1a0e705bf41d6e0e6424e" ]]; then
  say "Исправление ошибки Wine с DNS-серверами"
  cp "$IPHLP" "$IPHLP.orig"; cp "$IPHLP" "$IPHLP.new"
  # 0x11120 (свободное место в .text): size = 160; две исходные инструкции; jmp обратно на 0x57e8
  printf '\xc7\x44\x24\x6c\xa0\x00\x00\x00\x48\x8d\x44\x24\x6c\x48\x89\x44\x24\x28\xe9\xb1\x46\xff\xff' | dd of="$IPHLP.new" bs=1 seek=$((0x11120)) conv=notrunc 2>/dev/null
  # 0x57de: jmp на вставку вместо этих двух инструкций
  printf '\xe9\x3d\xb9\x00\x00\x90\x90\x90\x90\x90' | dd of="$IPHLP.new" bs=1 seek=$((0x57de)) conv=notrunc 2>/dev/null
  mv -f "$IPHLP.new" "$IPHLP"
fi

export PATH="$WINE_APP/Contents/Resources/wine/bin:$PATH"
export WINEPREFIX="$ROOT/prefix"
export WINEDEBUG=-all MVK_CONFIG_LOG_LEVEL=0
wine --version >/dev/null || fail "Wine не запускается"

SYS="$WINEPREFIX/drive_c/windows"
NETDIR="$SYS/Microsoft.NET/Framework64/v4.0.30319"

# ---------------------------------------------------------------- .NET 4.8
if [[ ! -f "$NETDIR/clr.dll" ]]; then
  say "Создание окружения Windows"
  wineboot -i >/dev/null 2>&1; wineserver -w
  wine winecfg -v win7 >/dev/null 2>&1

  say "Установка Microsoft .NET Framework 4.8 (несколько минут, без вывода — это нормально)"
  fetch "$NET48_URL" "$CACHE/ndp48.exe"
  WINEDLLOVERRIDES="mscoree=n,b;fusion=b" wine "$CACHE/ndp48.exe" /q /norestart >/dev/null 2>&1 || true
  wineserver -w
  [[ -f "$NETDIR/clr.dll" ]] || fail ".NET Framework 4.8 не установился"
fi

# Установщик 4.8 пропускает mscoree.dll на Windows 7+, поэтому Wine продолжает
# отправлять .NET-программы в Mono. Берём загрузчик Microsoft из пакета 4.0.
if ! grep -qa "Microsoft Corporation" "$SYS/system32/mscoree.dll" 2>/dev/null \
   || grep -qa "Wine builtin DLL" "$SYS/system32/mscoree.dll"; then
  say "Установка загрузчика .NET"
  fetch "$NET40_URL" "$CACHE/dotNetFx40.exe"
  N40="$CACHE/net40"; rm -rf "$N40"; mkdir -p "$N40"
  WINEDLLOVERRIDES="mscoree=b" wine "$CACHE/dotNetFx40.exe" /q "/x:$(winepath -w "$N40")" >/dev/null 2>&1 || true
  wineserver -w
  wine extrac32 /Y /E /L "$(winepath -w "$N40/out")" "$(winepath -w "$N40/netfx_Core.mzz")" >/dev/null 2>&1 || true
  wineserver -w
  [[ -f "$N40/out/_003_mscoree_dll_amd64" ]] || fail "Не удалось распаковать mscoree.dll"
  cp "$N40/out/_003_mscoree_dll_amd64" "$SYS/system32/mscoree.dll"
  cp "$N40/out/_003_mscoree_dll_x86"   "$SYS/syswow64/mscoree.dll"
  rm -rf "$N40"
fi
export WINEDLLOVERRIDES="mscoree=n"

# ---------------------------------------------------------------- настройки
say "Настройка интеграции с macOS"
wine reg add 'HKCU\Software\Wine\DllOverrides' /v mscoree /d native /f >/dev/null 2>&1
# Cmd+C / Cmd+V и т.д. работают как Ctrl
for k in LeftCommandIsCtrl RightCommandIsCtrl; do
  wine reg add 'HKCU\Software\Wine\Mac Driver' /v $k /d y /f >/dev/null 2>&1
done
# Выгруженные файлы открываются в приложении Mac по умолчанию (Excel, Numbers, Просмотр...)
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
# Регион Mac вроде en_UZ Wine не знает: раскладка получает код языка 0x1000,
# и iiko падает при переключении на русскую раскладку (CultureNotFoundException).
export LANG=ru_RU.UTF-8 LC_ALL=ru_RU.UTF-8
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
    say "Загрузка $name $VERSION с сервера iiko (около 500 МБ)"
    setup="$CACHE/Setup.$p.$VERSION.exe"
    fetch "$IIKO_BASE/$VERSION/iiko/$p/BackOffice/Setup.$p.BackOffice.exe" "$setup"

    say "Распаковка $name"
    # Установщик — пакет WiX: PE-заглушка, за которой идут два cab-архива
    # (манифест/интерфейс и полезная нагрузка). Вырезаем оба по заголовкам.
    layout="$CACHE/layout-$p"; rm -rf "$layout" "$dest"
    mkdir -p "$layout/ux" "$layout/pl" "$layout/msi" "$dest"
    cabs=()
    for off in $(grep -abo "MSCF" "$setup" | head -20 | cut -d: -f1); do
      size=$(tail -c +$((off + 9)) "$setup" | head -c 4 | od -An -tu4 | tr -d ' ')
      (( size > 100000 )) && cabs+=("$off:$size")
      (( $#cabs == 2 )) && break
    done
    (( $#cabs == 2 )) || fail "Неожиданная структура установщика $name"
    tail -c +$(( ${cabs[1]%%:*} + 1 )) "$setup" | head -c ${cabs[1]##*:} > "$layout/ux.cab"
    tail -c +$(( ${cabs[2]%%:*} + 1 )) "$setup" | head -c ${cabs[2]##*:} > "$layout/pl.cab"
    rm -f "$setup"
    wine extrac32 /Y /E /L "$(winepath -w "$layout/ux")" "$(winepath -w "$layout/ux.cab")" >/dev/null 2>&1 || true
    wine extrac32 /Y /E /L "$(winepath -w "$layout/pl")" "$(winepath -w "$layout/pl.cab")" >/dev/null 2>&1 || true
    wineserver -w
    rm -f "$layout/pl.cab"

    # Манифест сопоставляет идентификаторы (a10, a15, ...) с именами файлов
    payloads=$(grep -o '<Payload [^>]*>' "$layout/ux/0")
    msi_id=$(print -r -- "$payloads" | grep -E 'BackOffice\.x64\.msi"' | head -1 | sed -E 's/.*SourcePath="([^"]*)".*/\1/')
    cab_line=$(print -r -- "$payloads" | grep -E 'FilePath="packages\\BackOffice\\[^"]*\.cab"' | head -1)
    cab_id=$(print -r -- "$cab_line" | sed -E 's/.*SourcePath="([^"]*)".*/\1/')
    cab_name=$(print -r -- "$cab_line" | sed -E 's/.*FilePath="packages\\BackOffice\\([^"]*)".*/\1/')
    [[ -f "$layout/pl/$msi_id" && -f "$layout/pl/$cab_id" ]] || fail "Не удалось распаковать установщик $name"
    mv "$layout/pl/$msi_id" "$layout/msi/app.msi"
    mv "$layout/pl/$cab_id" "$layout/msi/$cab_name"
    rm -rf "$layout/pl"

    wine msiexec /a "$(winepath -w "$layout/msi/app.msi")" /qn TARGETDIR="$(winepath -w "$dest")" >/dev/null 2>&1 || true
    wineserver -w
    exe=$(find "$dest" -name BackOffice.exe -not -path "*/Cef/*" | head -1)
    [[ -n "$exe" ]] || fail "Не удалось извлечь $name"
    rm -rf "$layout"
  fi
  make_app "$name" "${exe:h}"
  say "$name установлен -> $APPS_DIR/$name.app"
done

rm -rf "$CACHE"/wine.tar.xz "$CACHE"/ndp48.exe "$CACHE"/dotNetFx40.exe
rmdir "$CACHE" 2>/dev/null || true

print
say "Готово. Откройте $APPS_DIR и запустите iikoOffice / iikoChain."
print "    В окне входа нажмите «Дополнительно >>» и введите адрес сервера."
