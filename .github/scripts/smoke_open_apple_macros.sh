#!/usr/bin/env bash
# Prove a built xcross bundle carries a working OpenAppleMacrosServer.
#
# Usage: smoke_open_apple_macros.sh <bundle-dir>
#
# Type-checks a probe that expands PreviewsMacros (including the xcross fork's
# UIKit/AppKit #Preview stub) through the bundled server, which exercises the
# compiler plugin handshake end to end. On Linux it also checks the server
# needs no Swift runtime library at run time.
set -euo pipefail

bundle=${1:?usage: $0 <bundle-dir>}
case "$(uname -s)" in
MINGW* | MSYS* | CYGWIN*) server="$bundle/lib/OpenAppleMacrosServer.exe" ;;
*) server="$bundle/lib/OpenAppleMacrosServer" ;;
esac
[ -s "$server" ] || {
	echo "missing bundled server: $server" >&2
	exit 1
}

if [ "$(uname -s)" = Linux ]; then
	# The static Linux SDK produces a fully static executable.
	if file "$server" | grep -q 'dynamically linked'; then
		file "$server" >&2
		echo "bundled server is not statically linked" >&2
		exit 1
	fi
fi

probe=$(mktemp -d)
trap 'rm -rf "$probe"' EXIT
cat >"$probe/probe.swift" <<'SWIFT'
@freestanding(declaration)
macro SwiftUIView(_ body: () -> Void) =
  #externalMacro(module: "PreviewsMacros", type: "SwiftUIView")

@freestanding(declaration)
macro KitViewMacro(_ body: () -> Void) =
  #externalMacro(module: "PreviewsMacros", type: "KitViewMacro")

struct Probe {
  #SwiftUIView { }
  #KitViewMacro { }
}
SWIFT

if [ -n "${WINDIR:-}" ]; then
	echo "Bundled lib/:"
	ls -la "$(dirname "$server")"
	# A server missing a DLL dies before speaking the plugin protocol; run it
	# alone with stdin closed so the loader error is visible.
	set +e
	PATH="$(dirname "$server"):/c/Windows/System32:/c/Windows" "$server" </dev/null
	status=$?
	set -e
	echo "standalone server exit: $status"
	if [ "$status" -ne 0 ]; then
		echo "bundled server cannot start on its own (0xC0000135 = missing DLL)" >&2
		exit 1
	fi
fi

# Run the server with the Swift toolchain off PATH so a Windows bundle has to
# load its runtime DLLs from lib/, exactly as on a user's machine.
swiftc=$(command -v swiftc)
if [ -n "${WINDIR:-}" ]; then
	PATH="$(dirname "$server"):/usr/bin:/bin" \
		"$swiftc" -typecheck "$probe/probe.swift" \
		-load-plugin-executable "$server#PreviewsMacros"
else
	"$swiftc" -typecheck "$probe/probe.swift" \
		-load-plugin-executable "$server#PreviewsMacros"
fi
echo "OpenAppleMacrosServer handshake OK: $server"
