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

if ! have_fixed_lld; then
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
