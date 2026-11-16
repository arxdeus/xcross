#!/usr/bin/env bash
# Prove a built xcross bundle carries a working xcrun.
#
# Usage: smoke_xcrun.sh <bundle-dir>
#
# `dart build cli` can emit a thin launcher in bin/ that loads its AOT payload
# from lib/. A launcher shipped without its payload silently runs as a bare
# Dart runtime instead of failing (#165), so check the answer, not the exit.
set -euo pipefail

bundle=${1:?usage: $0 <bundle-dir>}
case "$(uname -s)" in
MINGW* | MSYS* | CYGWIN*) xcrun="$bundle/bin/xcrun.exe" ;;
*) xcrun="$bundle/bin/xcrun" ;;
esac
[ -s "$xcrun" ] || {
	echo "missing bundled xcrun: $xcrun" >&2
	exit 1
}

output=$("$xcrun" --version | tr -d '\r')
echo "$output"
case "$output" in
"xcrun version "*) ;;
*)
	echo "bundled xcrun is not the xcross xcrun" >&2
	ls -l "$bundle/bin" "$bundle/lib" >&2 || true
	exit 1
	;;
esac
