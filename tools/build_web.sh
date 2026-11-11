#!/usr/bin/env bash
# Builds the web page (build-web/PaxDino.html, .js, .wasm, .data) from the USA ROM, on Linux with emsdk active
# (N64Recomp-browser's README, Using it in a recomp, says what else: naga, spirv-opt, ccache), clang, Ninja and
# Python 3, as rush-2049-recomp's Docker image has them:
#
#   bash tools/build_web.sh <USA ROM> [<jobs>] [--prepare]
#   bash tools/build_web.sh --patches          step 1 alone: no ROM, and only git and CMake
#
# 1. The submodules and their patches, from clean whenever lib-patches/, lib/N64Recomp-browser or web/patches moved
#    since the last time (build-web-prep/web-patched records it): apply.cmake can't take a checkout from one version
#    of its patches to another. First the game's own, lib-patches/<project>/*.patch in order, as the desktop build's
#    cmake/ApplyLibPatches.cmake applies them (CMakeLists.txt leaves them to this script with Emscripten); then
#    N64Recomp-browser's web support (lib/N64Recomp-browser/patches/apply.cmake, project by project), but for the
#    files where the two change the same lines: the web's change to those (web/patches/files.txt) is
#    web/patches/<project>.patch instead, made on top of the game's from the N64Recomp-browser commit
#    web/patches/files.txt names, with what the web has changed in them since merged in by apply.cmake --since (only a
#    change that meets the game's own lines stops the build, for another merge by hand). A file marked own there
#    keeps the game's code alone: the web's change to it is left out, then and later.
# 2. N64Recomp and RSPRecomp, built natively from the patched lib/N64ModernRuntime/N64Recomp: the page needs the code
#    the web-patched N64Recomp writes, and the game's own N64Recomp patches are on it too.
# 3. The recompiled game (RecompiledFuncs/) and the audio microcode (rsp/aspMain.cpp) from turokrw.us.z64, a copy of
#    the ROM given, as BUILDING.md makes them for the desktop: again only when the ROM, the configs, the symbols or the
#    recompilers changed (build-web-prep/recompiled-stamp).
# 4. The page, with emcmake, in build-web (CMakeLists.txt's EMSCRIPTEN parts). --prepare stops before it.
# --patches stops after step 1. N64Recomp-browser's CI runs it with its own checkout as lib/N64Recomp-browser and the
# submodules checked out, so a web change there that meets this port's own lines in a file left out is red where it is
# made: merge it into the patch by hand then.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
[[ $# -ge 1 ]] || { echo "usage: $0 <USA ROM> [<jobs>] [--prepare] | --patches" >&2; exit 2; }
patches_only=0
[[ "$1" == --patches ]] && patches_only=1
[[ $patches_only == 1 ]] || rom="$(realpath "$1")"
jobs="$(nproc)"
prepare_only=0
for a in "${@:2}"; do
    case "$a" in
    --prepare) prepare_only=1 ;;
    *) jobs="$a" ;;
    esac
done
cd "$root"
browser=lib/N64Recomp-browser
prep=build-web-prep
mkdir -p $prep

step() { printf '\n== %s\n' "$*"; }

# --- 1. Submodules and patches ---
step "Submodules"
[[ -f lib/rt64/CMakeLists.txt && -f lib/N64ModernRuntime/N64Recomp/CMakeLists.txt && -f lib/RecompFrontend/CMakeLists.txt &&
   -f $browser/patches/apply.cmake ]] ||
    git submodule update --init --recursive lib/rt64 lib/N64ModernRuntime lib/RecompFrontend $browser

step "Patches"
# <name> <checkout> [files left to web/patches/<name>.patch, merged from the commit files.txt names, or left out]
shared() { awk -v p="$1" '!/^#/ && $1 == p { printf "%s ", $2 }' web/patches/files.txt; }
merged() { awk -v p="$1" '!/^#/ && $1 == p && $3 != "own" { printf "%s ", $2 }' web/patches/files.txt; }
merged_from="$(sed -n 's/^# merged from N64Recomp-browser //p' web/patches/files.txt)"
web_patches="rt64 lib/rt64 $(shared rt64)
plume lib/rt64/src/contrib/plume $(shared plume)
hlslpp lib/rt64/src/contrib/hlslpp $(shared hlslpp)
N64ModernRuntime lib/N64ModernRuntime $(shared N64ModernRuntime)
N64Recomp lib/N64ModernRuntime/N64Recomp $(shared N64Recomp)
RecompFrontend lib/RecompFrontend $(shared RecompFrontend)"
# The game's own patches: <folder in lib-patches/> <checkout>, as CMakeLists.txt applies them.
own_patches="rt64 lib/rt64
N64Recomp lib/N64ModernRuntime/N64Recomp
N64ModernRuntime lib/N64ModernRuntime
RecompFrontend lib/RecompFrontend"
stamp="$(git -C $browser rev-parse HEAD) $( (cat lib-patches/*/*.patch web/patches/*.patch web/patches/files.txt 2> /dev/null
    echo "$web_patches") | sha1sum | cut -c1-40)"
# A checkout reset since (rt64 clean) is patched again whatever the stamp says.
if [[ "$(cat $prep/web-patched 2> /dev/null)" != "$stamp" ]] || git -C lib/rt64 diff --quiet; then
    for s in lib/rt64 lib/N64ModernRuntime lib/RecompFrontend; do
        git -C $s submodule foreach --recursive -q 'git reset -q --hard && git clean -fdq'
        git -C $s reset -q --hard && git -C $s clean -fdq
        rm -f "$(git -C $s rev-parse --path-format=absolute --git-dir)"/n64recomp-browser-*
    done
    while read -r dir checkout; do
        for patch in lib-patches/$dir/*.patch; do
            git -C "$checkout" apply --ignore-whitespace --whitespace=nowarn "$root/$patch" ||
                { echo "lib-patches: $patch doesn't apply to $checkout"; exit 1; }
        done
    done <<< "$own_patches"
    while read -r name checkout skip; do
        cmake -P $browser/patches/apply.cmake "$name" "$checkout" $skip
        [[ ! -f web/patches/$name.patch ]] || git -C "$checkout" apply --whitespace=nowarn "$root/web/patches/$name.patch"
        since="$(merged "$name")"
        [[ -z "$since" ]] || cmake -P $browser/patches/apply.cmake "$name" "$checkout" --since "$merged_from" $since
    done <<< "$web_patches"
    echo "$stamp" > $prep/web-patched
fi

[[ $patches_only == 1 ]] && exit 0

# --- 2. N64Recomp and RSPRecomp ---
step "N64Recomp"
tools=$prep/tools
[[ -f $tools/build.ninja ]] || cmake -S lib/N64ModernRuntime/N64Recomp -B $tools -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ > /dev/null
ninja -C $tools N64RecompCLI RSPRecomp > /dev/null

# --- 3. The recompiled game and the audio microcode ---
step "Recompiled code"
cmp -s "$rom" turokrw.us.z64 || cp "$rom" turokrw.us.z64
inputs="$( (cat turokrw.us.z64 turokrw.us.toml aspMain.us.toml TurokRWSyms/* $tools/N64Recomp $tools/RSPRecomp) |
    sha1sum | cut -c1-40)"
if [[ "$(cat $prep/recompiled-stamp 2> /dev/null)" != "$inputs" || ! -f RecompiledFuncs/funcs.h ||
      ! -f rsp/aspMain.cpp ]]; then
    rm -rf RecompiledFuncs rsp
    mkdir -p rsp
    ("$tools/N64Recomp" turokrw.us.toml && "$tools/RSPRecomp" aspMain.us.toml) > $prep/n64recomp.log 2>&1 ||
        { tail -20 $prep/n64recomp.log; exit 1; }
    echo "$inputs" > $prep/recompiled-stamp
fi
[[ $prepare_only == 1 ]] && exit 0

# --- 4. The page ---
step "Page"
embuilder build sdl2-mt freetype-legacysjlj > /dev/null 2>&1
# CMakeLists.txt gives RT64 web/rt64_shaders.txt only if it exists, which ninja doesn't know to configure again for.
list="$( [[ -f web/rt64_shaders.txt ]] && echo list || echo none)"
[[ "$(cat $prep/shader-list 2> /dev/null)" == "$list" ]] || rm -f build-web/build.ninja
[[ -f build-web/build.ninja ]] || emcmake cmake -S . -B build-web -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DRT64_NAGA_EXECUTABLE="$(command -v naga)" -DPython3_EXECUTABLE="$(command -v python3)" > $prep/configure.log 2>&1 ||
    { tail -30 $prep/configure.log; rm -f build-web/build.ninja; exit 1; }
echo "$list" > $prep/shader-list
cmake --build build-web --target PaxDino -j"$jobs"
ls -l build-web/PaxDino.{html,js,wasm,data}
