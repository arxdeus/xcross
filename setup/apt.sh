#!/usr/bin/env sh
set -eu

if [ "$(id -u)" -eq 0 ]; then
	SUDO=""
elif command -v sudo >/dev/null 2>&1; then
	SUDO="sudo"
else
	printf '%s\n' 'error: apt setup requires root or sudo' >&2
	exit 1
fi

packages="
clang llvm
python3 python3-pip python3-venv pipx
usbmuxd usbutils libimobiledevice-utils
pkg-config zlib1g-dev libpython3-dev gcc g++ curl
libxml2-dev libncurses-dev libz3-dev gnupg2
libc6-dev libcurl4-openssl-dev
lsb-release wget software-properties-common ca-certificates
"

$SUDO apt-get update
# Package expansion is intentional: each whitespace-delimited name is an argument.
# shellcheck disable=SC2086
$SUDO apt-get install -y $packages

# Xcode 26 libc++ headers require Clang 20 builtins (notably __builtin_clzg).
# Keep the linker requirement separate: LLVM 19 fixed Objective-C stubs.
min_clang=20
have_recent_clang() {
	for bin in /usr/bin/clang-[0-9]*; do
		[ -x "$bin" ] || continue
		version="${bin##*/clang-}"
		case "$version" in '' | *[!0-9]*) continue ;; esac
		[ "$version" -ge "$min_clang" ] && return 0
	done
	return 1
}

# Up to and including LLVM 18, ld64.lld miswires `_objc_msgSend$<selector>`
# stubs, which breaks Objective-C plugins at runtime. Ubuntu 24.04 still
# ships 18 as the unversioned `lld`, and older releases have nothing newer in
# their archive at all. Install lld from apt.llvm.org instead, which always
# carries a current versioned `lld-<N>`, then point stable names at its
# linkers.
min_lld=19

have_fixed_lld() {
	for bin in /usr/bin/ld64.lld-*; do
		[ -x "$bin" ] || continue
		version="${bin##*/ld64.lld-}"
		case "$version" in
		'' | *[!0-9]*) continue ;;
		esac
		[ "$version" -ge "$min_lld" ] && return 0
	done
	return 1
}

if ! have_fixed_lld || ! have_recent_clang; then
	# llvm.sh adds the apt.llvm.org repository for this distro and installs the
	# named component; with no version argument it picks the current stable one.
	llvm_dir="$(mktemp -d)"
	if curl -fsSL https://apt.llvm.org/llvm.sh -o "$llvm_dir/llvm.sh"; then
		# `bash <file>`, not `./llvm.sh`: the script is bash-only, and a
		# noexec /tmp would otherwise fail it. No version argument, so it
		# installs the current stable clang/lld/lldb for this distro.
		$SUDO bash "$llvm_dir/llvm.sh" || true
	else
		printf 'warning: could not download https://apt.llvm.org/llvm.sh\n' >&2
	fi
	rm -rf "$llvm_dir"
	if ! have_fixed_lld; then
		# Last resort: whatever versioned lld this host's own archive offers.
		for candidate in $(apt-cache pkgnames lld- 2>/dev/null | sed -n 's/^lld-\([0-9][0-9]*\)$/\1/p' | sort -rn); do
			if [ "$candidate" -ge "$min_lld" ]; then
				$SUDO apt-get install -y "lld-$candidate" || true
				break
			fi
		done
	fi
fi

if ! have_recent_clang; then
	for candidate in $(apt-cache pkgnames clang- 2>/dev/null | sed -n 's/^clang-\([0-9][0-9]*\)$/\1/p' | sort -rn); do
		if [ "$candidate" -ge "$min_clang" ]; then
			$SUDO apt-get install -y "clang-$candidate" || true
			break
		fi
	done
fi
if ! have_recent_clang; then
	printf 'error: Clang %s+ is required for Xcode 26 SDK headers; install it from https://apt.llvm.org/ and retry.\n' "$min_clang" >&2
	exit 1
fi

# Give xcross a stable PATH entry without replacing distribution-managed clang.
best_clang=0
for bin in /usr/bin/clang-[0-9]*; do
	[ -x "$bin" ] || continue
	version="${bin##*/clang-}"
	case "$version" in '' | *[!0-9]*) continue ;; esac
	if [ "$version" -gt "$best_clang" ]; then best_clang="$version"; fi
done
for tool in clang clang++; do
	stable="/usr/local/bin/$tool"
	if [ ! -e "$stable" ] && [ ! -L "$stable" ]; then
		$SUDO ln -s "/usr/bin/$tool-$best_clang" "$stable"
	elif [ -L "$stable" ]; then
		case "$(readlink "$stable")" in
		/usr/bin/"$tool"-[0-9]*) $SUDO ln -sf "/usr/bin/$tool-$best_clang" "$stable" ;;
		esac
	fi
done

clang_major=$(clang --version | sed -n '1s/.*version \([0-9][0-9]*\).*/\1/p')
if [ -z "$clang_major" ] || [ "$clang_major" -lt "$min_clang" ]; then
	printf 'error: clang on PATH is %s; configure your PATH to select /usr/bin/clang-%s instead of the older installation.\n' "${clang_major:-unknown}" "$best_clang" >&2
	exit 1
fi

# Put the newest fixed lld on PATH under its unversioned names, unless
# something xcross does not manage already owns those paths.
best_version=0
best=""
for bin in /usr/bin/ld64.lld-*; do
	[ -x "$bin" ] || continue
	version="${bin##*/ld64.lld-}"
	case "$version" in
	'' | *[!0-9]*) continue ;;
	esac
	[ "$version" -lt "$min_lld" ] && continue
	if [ "$version" -gt "$best_version" ]; then
		best_version="$version"
		best="$bin"
	fi
done

if [ -n "$best" ]; then
	stable=/usr/local/bin/ld64.lld
	managed=0
	if [ ! -e "$stable" ] && [ ! -L "$stable" ]; then
		managed=1
	elif [ -L "$stable" ]; then
		case "$(readlink "$stable")" in
		*/ld64.lld-*) managed=1 ;;
		esac
	fi
	if [ "$managed" -eq 1 ]; then
		$SUDO ln -sf "$best" "$stable"
		printf 'ld64.lld: %s -> %s\n' "$stable" "$best"
	else
		printf 'warning: %s is not managed by xcross; leaving it alone (wanted %s)\n' "$stable" "$best" >&2
	fi

	# apt.llvm.org only installs versioned names, so the ELF driver (`ld.lld`,
	# used by `clang -fuse-ld=lld`) needs an unversioned entry point too.
	if [ -x "/usr/bin/ld.lld-$best_version" ] && command -v update-alternatives >/dev/null 2>&1; then
		$SUDO update-alternatives --install /usr/bin/ld.lld ld.lld \
			"/usr/bin/ld.lld-$best_version" "$best_version" || true
		printf 'ld.lld: /usr/bin/ld.lld -> /usr/bin/ld.lld-%s\n' "$best_version"
	fi
fi

if ! command -v swift >/dev/null 2>&1; then
	swiftly_dir="$(mktemp -d)"
	trap 'rm -rf "$swiftly_dir"' EXIT HUP INT TERM
	curl -fsSL "https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz" \
		-o "$swiftly_dir/swiftly.tar.gz"
	tar -xzf "$swiftly_dir/swiftly.tar.gz" -C "$swiftly_dir"
	"$swiftly_dir/swiftly" init --quiet-shell-followup
	. "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh"
	hash -r
fi

pipx install --force pymobiledevice3
pipx ensurepath
