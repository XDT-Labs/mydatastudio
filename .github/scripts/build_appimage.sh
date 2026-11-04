#!/usr/bin/env bash
# Turns a Flutter Linux bundle into a self-contained tree (AppDir) and an AppImage.
#
# The bundle alone is tied to the build machine: it links libmpv.so.1, while
# Ubuntu 24.04 ships libmpv.so.2, so it wouldn't start there even with libmpv
# installed. libmpv and its dependencies therefore go in the tree, along with
# the `unzip` command PythonManager runs.
#
# What's left to the system is named in SYSTEM_LIBS below. Everything else the
# app's libraries need goes in the tree. Sonames vary by distro (Fedora has no
# libjpeg.so.8, Debian 13 no libgcrypt by default), so "whatever GTK happens to
# link to here" isn't a safe definition of the system's share.
#
# Libraries are found through RUNPATH, not LD_LIBRARY_PATH, which would leak into
# everything the app launches, such as the user's browser through xdg-open.
#
# Usage: build_appimage.sh <bundle-dir> <appdir-to-create> <output.AppImage>
# Needs: patchelf, objdump, file, unzip, curl.
set -euo pipefail

bundle=$(cd "$1" && pwd)
appdir=$2
output=$3

case "$(uname -m)" in
  x86_64)
    arch=x86_64
    tool_sha=ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0
    runtime_sha=2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d
    ;;
  aarch64)
    arch=aarch64
    tool_sha=f0837e7448a0c1e4e650a93bb3e85802546e60654ef287576f46c71c126a9158
    runtime_sha=00cbdfcf917cc6c0ff6d3347d59e0ca1f7f45a6df1a428a0d6d8a78664d87444
    ;;
  *) echo "Error: unsupported architecture $(uname -m)"; exit 1 ;;
esac

# Pinned, because appimagetool otherwise fetches whatever runtime is newest.
tool_url=https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-$arch.AppImage
runtime_url=https://github.com/AppImage/type2-runtime/releases/download/20251108/runtime-$arch

mkdir -p "$appdir"
appdir=$(cd "$appdir" && pwd)
cp -a "$bundle/." "$appdir/"
mkdir -p "$appdir/usr/bin"
cp "$(command -v unzip)" "$appdir/usr/bin/unzip"

work=$(mktemp -d)

# glibc and the C++ runtime; the GL stack, which has to match the machine's
# drivers; GTK and its family, which load system modules and themes; and a few
# stable compression and parsing libraries that a newer system's own libraries
# may need a newer version of than this older build machine has.
SYSTEM_LIBS='^(ld-linux.*|libc|libdl|libm|libpthread|librt|libresolv|libutil|libnsl|libstdc\+\+|libgcc_s'
SYSTEM_LIBS+='|libGL|libEGL|libGLX|libOpenGL|libGLdispatch|libdrm|libgbm'
SYSTEM_LIBS+='|libgtk-3|libgdk-3|libgdk_pixbuf-2\.0|libatk-1\.0|libatk-bridge-2\.0|libatspi|libepoxy'
SYSTEM_LIBS+='|libcairo|libcairo-gobject|libpango-1\.0|libpangocairo-1\.0|libpangoft2-1\.0|libharfbuzz'
SYSTEM_LIBS+='|libfontconfig|libfreetype|libglib-2\.0|libgio-2\.0|libgobject-2\.0|libgmodule-2\.0|libgthread-2\.0'
SYSTEM_LIBS+='|libX11|libX11-xcb|libXext|libXrender|libXfixes|libXcursor|libXdamage|libXcomposite|libXrandr|libXi|libXinerama'
SYSTEM_LIBS+='|libxcb|libxcb-render|libxcb-shm|libxkbcommon|libwayland-client|libwayland-cursor|libwayland-egl|libdbus-1'
SYSTEM_LIBS+='|libz|libzstd|liblzma|libexpat)\.so'

# Walks dependencies from the app outward, stopping at the system's share, so
# libraries only the system's GTK needs don't get copied.
queue=("$appdir/mydatastudio" "$appdir"/lib/*.so "$appdir/usr/bin/unzip")
copied=()
while [ "${#queue[@]}" -gt 0 ]; do
  file=${queue[0]}
  queue=("${queue[@]:1}")
  for name in $(objdump -p "$file" | awk '/NEEDED/{print $2}'); do
    [ -e "$appdir/lib/$name" ] && continue
    echo "$name" | grep -qE "$SYSTEM_LIBS" && continue
    lib=$(LD_LIBRARY_PATH="$appdir/lib" ldd "$file" | awk -v n="$name" '$1 == n && $3 ~ /^\// {print $3}')
    [ -n "$lib" ] || { echo "Error: $(basename "$file") needs $name, which isn't installed"; exit 1; }
    cp -L "$lib" "$appdir/lib/$name"
    chmod u+w "$appdir/lib/$name"
    queue+=("$appdir/lib/$name")
    copied+=("$appdir/lib/$name")
  done
done
echo "Bundled ${#copied[@]} libraries, $(du -sh "$appdir/lib" | cut -f1) in lib/"

# Only after the walk, which needs each library's original RUNPATH: libpulse
# finds libpulsecommon through its own. Plugins need lib/ too.
for file in "${copied[@]}" "$appdir"/lib/*_plugin.so; do
  patchelf --set-rpath '$ORIGIN' "$file"
done
patchelf --set-rpath '$ORIGIN/../../lib' "$appdir/usr/bin/unzip"

cat > "$appdir/AppRun" <<'EOF'
#!/bin/sh
here=$(dirname "$(readlink -f "$0")")
PATH="$here/usr/bin:$PATH" exec "$here/mydatastudio" "$@"
EOF
chmod +x "$appdir/AppRun"

desktop=$(find "$appdir/data" -maxdepth 1 -name '*.desktop')
[ "$(echo "$desktop" | wc -l)" = 1 ] && [ -n "$desktop" ] || { echo "Error: expected one .desktop file in data/"; exit 1; }
app_id=$(basename "$desktop" .desktop)
cp "$desktop" "$appdir/$app_id.desktop"
cp "$appdir/data/app_icon.png" "$appdir/$app_id.png"
ln -sf "$app_id.png" "$appdir/.DirIcon"

fetch() { # url sha256 destination
  curl -fsSL --retry 3 -o "$3" "$1"
  echo "$2  $3" | sha256sum -c --quiet -
}
fetch "$tool_url" "$tool_sha" "$work/appimagetool"
fetch "$runtime_url" "$runtime_sha" "$work/runtime"
chmod +x "$work/appimagetool"

# Extract-and-run because runners and containers may lack FUSE.
ARCH=$arch "$work/appimagetool" --appimage-extract-and-run \
  --runtime-file "$work/runtime" --comp zstd --no-appstream "$appdir" "$output"
ls -la "$output"
