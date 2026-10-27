# Pinned upstream binaries. Bump with:
#
#   nix store prefetch-file --json <url> | jq -r .hash
#
# The xcross archives are the GitHub release assets; their SHA256SUMS.txt
# covers the same files.
{
  xcross = rec {
    version = "2.0.5";
    sources = {
      x86_64-linux = {
        url = "https://github.com/arxdeus/xcross/releases/download/v${version}/xcross-linux-x64.tar.gz";
        hash = "sha256-WCwjsxghDgndLAk4iHLdbrL6YU6XU7rPf+0NHn336fA=";
      };
      aarch64-linux = {
        url = "https://github.com/arxdeus/xcross/releases/download/v${version}/xcross-linux-arm64.tar.gz";
        hash = "sha256-JXxEswWSpatbAnWfpzJLR+dqhg2cS2w7s1deXGzK0ms=";
      };
    };
  };

  # Keep in sync with SWIFT_VERSION in .github/workflows/integration.yml and
  # min_swift in setup/*.sh.
  swift = rec {
    version = "6.4.0";
    sources = {
      x86_64-linux = {
        url = "https://download.swift.org/swift-${version}-release/ubuntu2404/swift-${version}-RELEASE/swift-${version}-RELEASE-ubuntu24.04.tar.gz";
        hash = "sha256-afeytNvOYJC2ySGUtxFJoFfhYmkJO1qd3tOK/EoFCU4=";
      };
      aarch64-linux = {
        url = "https://download.swift.org/swift-${version}-release/ubuntu2404-aarch64/swift-${version}-RELEASE/swift-${version}-RELEASE-ubuntu24.04-aarch64.tar.gz";
        hash = "sha256-IerP5XEZRxfSacweADBTO77mEx396CzU+c+8JRLjVKk=";
      };
    };
  };
}
