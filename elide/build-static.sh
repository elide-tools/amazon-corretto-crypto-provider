#!/usr/bin/env bash
# Build ACCP's JNI adapter as a static archive (libamazonCorrettoCryptoProvider.a) for one target
# triple with the elide-dev/toolchain bundle. AWS-LC is not linked in: the final link supplies the
# unprefixed libcrypto (the bundle's, or aws-lc-sys's), pinned to the same AWS-LC release.
#
# Members are ThinLTO bitcode for the bundle's LLVM: fat objects (native code + .llvm.lto) on Linux,
# pure bitcode on darwin (Mach-O has no fat objects), matching every other toolchain archive.
#
# Usage: elide/build-static.sh SOURCES_JAR TRIPLE OUT_DIR
#   ELIDE_TOOLCHAIN_HOME  bundle root (set by the elide-dev/toolchain action)
#   JAVA_HOME             JDK for javac -h and the JNI headers
# Ported from Elide's tools/jvm/accp-static.mts.
set -euo pipefail

jar="$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"
triple="$2"
out="$3"
tc="${ELIDE_TOOLCHAIN_HOME:?set ELIDE_TOOLCHAIN_HOME to the toolchain bundle}"
jdk="${JAVA_HOME:?set JAVA_HOME}"
[ -f "$jar" ] || { echo "no sources jar: $jar" >&2; exit 1; }
[ -x "$tc/bin/$triple-clang++" ] || { echo "toolchain has no $triple-clang++" >&2; exit 1; }

# AWS-LC lockstep: the bundle's libcrypto (and its headers, used here) must be the release ACCP pins.
want="$(sed -n "s/^ext.awsLcMainTag = 'v\(.*\)'/\1/p" "$(dirname "$0")/../build.gradle")"
have="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["components"]["aws-lc"]["version"])' \
  "$tc/share/elide-toolchain/manifest.json")"
[ "$want" = "$have" ] || { echo "AWS-LC mismatch: ACCP pins $want, toolchain bundle has $have" >&2; exit 1; }

case "$triple" in
  *-linux-*) lto=(-flto=thin -ffat-lto-objects); jni_os=linux ;;
  *-apple-darwin*) lto=(-flto=thin); jni_os=darwin ;;
  *) echo "unsupported triple: $triple" >&2; exit 1 ;;
esac

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
src="$work/source" hdr="$work/headers" cls="$work/classes" obj="$work/obj"
mkdir -p "$src" "$hdr" "$cls" "$obj" "$out/lib"
(cd "$src" && "$jdk/bin/jar" xf "$jar")

# JNI headers for the native methods. --release 17, not 8: 2.6.0's ML-KEM Multi-Release overlay
# (jdk17plus/) needs JDK 17 APIs; javac -h emits the same headers either way.
find "$src" -name '*.java' ! -name module-info.java -print0 \
  | xargs -0 "$jdk/bin/javac" -nowarn --release 17 -h "$hdr" -d "$cls"
(cd "$hdr" && for h in *.h; do echo "#include \"$h\""; done) > "$hdr/generated-headers.h"

# config.h: the features clang/libc++ provide (CMake would probe these).
supported=" HAVE_ATTR_COLD HAVE_ATTR_NORETURN HAVE_ATTR_ALWAYS_INLINE HAVE_ATTR_NOINLINE HAVE_IS_TRIVIALLY_COPYABLE HAVE_NULLPTR HAVE_NOEXCEPT "
while IFS= read -r line; do
  if [[ "$line" =~ ^#cmakedefine[[:space:]]+([A-Za-z0-9_]+) ]]; then
    n="${BASH_REMATCH[1]}"
    if [[ "$supported" == *" $n "* ]]; then echo "#define $n"; else echo "/* $n disabled */"; fi
  else
    echo "$line"
  fi
done < "$src/csrc/config.h.in" > "$hdr/config.h"

# Statically linked JNI libraries must report JNI 1.8 or later (JEP 178).
sed -i.bak 's/return JNI_VERSION_1_4;/return JNI_VERSION_1_8;/' "$src/csrc/loader.cpp"
grep -c 'return JNI_VERSION_1_8;' "$src/csrc/loader.cpp" >/dev/null \
  || { echo "loader.cpp: JNI version patch did not apply" >&2; exit 1; }

version="$(sed -n 's/^versionStr=//p' "$src/com/amazon/corretto/crypto/provider/version.properties" | tr -d '[:space:]')"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "bad ACCP version '$version'" >&2; exit 1; }

flags=(-std=c++11 -O2 -fPIC -DNDEBUG -ffunction-sections -fdata-sections "${lto[@]}"
  # Unprefixed libcrypto: keep the prefix map in AWS-LC's headers inert.
  -DBORINGSSL_PREFIX_SYMBOLS_H
  -DJNI_OnLoad=JNI_OnLoad_amazonCorrettoCryptoProvider
  "-DPROVIDER_VERSION_STRING=$version"
  "-I$hdr" "-I$jdk/include" "-I$jdk/include/$jni_os")

n=0
for f in "$src"/csrc/*.cpp; do
  case "$(basename "$f")" in test_keyutils.cpp|test_util.cpp|testhooks.cpp) continue ;; esac
  "$tc/bin/$triple-clang++" "${flags[@]}" -c "$f" -o "$obj/$(basename "$f").o" &
  n=$((n + 1))
  if [ $((n % 8)) -eq 0 ]; then wait; fi
done
wait
a="$out/lib/libamazonCorrettoCryptoProvider.a"
rm -f "$a"
(cd "$obj" && "$tc/bin/llvm-ar" rcs "$a" ./*.o)   # glob order is sorted

# Checks: the loader symbol is defined, and every member carries bitcode.
"$tc/bin/llvm-nm" "$a" 2>/dev/null | awk '$3 ~ /JNI_OnLoad_amazonCorrettoCryptoProvider$/ { f = 1 } END { exit !f }' \
  || { echo "JNI_OnLoad_amazonCorrettoCryptoProvider not defined" >&2; exit 1; }
if [ "$jni_os" = linux ]; then
  for o in "$obj"/*.o; do
    "$tc/bin/llvm-readelf" -S "$o" | grep -c '\.llvm\.lto' >/dev/null \
      || { echo "$(basename "$o"): no .llvm.lto section (not a fat ThinLTO object)" >&2; exit 1; }
  done
else
  for o in "$obj"/*.o; do
    m="$(head -c 4 "$o" | od -An -tx1 | tr -d ' \n')"
    case "$m" in 4243c0de|dec0170b) ;; *) echo "$(basename "$o"): not LLVM bitcode (magic $m)" >&2; exit 1 ;; esac
  done
fi

{
  echo "accp_version=$version"
  echo "accp_commit=${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"
  echo "aws_lc=$want"
  echo "triple=$triple"
  echo "toolchain=$(cat "$tc/share/elide-toolchain/VERSION" 2>/dev/null || echo unknown)"
  echo "compiler=$("$tc/bin/$triple-clang++" --version | head -1)"
  echo "flags=${flags[*]}"
} > "$out/BUILDINFO"
echo "built $a ($(wc -c < "$a") bytes)"
