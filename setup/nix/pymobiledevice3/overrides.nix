# Extra / pinned Python packages needed to build pymobiledevice3.
#
# Consumed as a `packageOverrides` function for `pkgs.python313.override`, so
# `self` is the (fixpoint of the) Python package set and `super` the unmodified
# nixpkgs set.  `lib` is passed in by the caller.
{ lib }:
self: super: {
  # ---------------------------------------------------------------------------
  # Versions pinned to what upstream supports
  # ---------------------------------------------------------------------------

  # pymobiledevice3 pins `qh3>=1.0.0,<2`.  qh3 2.0 dropped
  # `qh3.quic.packet_builder`, which pymobiledevice3 imports to clamp the QUIC
  # datagram size to the device MTU (`remote/tunnel_service.py`), so 2.x is a
  # hard break rather than just a conservative bound.
  #
  # Prefer nixpkgs' own qh3 when it is already a 1.x: that build is in the
  # binary cache, whereas ours is a from-source Rust compile (~8 min).  Only
  # build the pinned copy once nixpkgs moves on.
  qh3 = if lib.versionAtLeast super.qh3.version "2" then self.callPackage ./qh3.nix { } else super.qh3;

  # PyIMG4 (used by pymobiledevice3 and ipsw-parser for restore) requires
  # `asn1<3`; see https://github.com/m1stadev/PyIMG4/issues/59.  pymobiledevice3
  # itself only uses the stable `Encoder`/`Decoder` API and works with 2.x, so
  # the whole set is pinned back to 2.8.0.  nixpkgs marks pyimg4 broken once
  # asn1 >= 3, so this also un-breaks it.
  asn1 = self.callPackage ./asn1.nix { };

  # ---------------------------------------------------------------------------
  # Packages missing from nixpkgs
  # ---------------------------------------------------------------------------

  # "pmd-pytcp" is the pure-Python userspace TCP/IP stack used for the no-root
  # iOS 17+ tunnel; it pulls in its two sibling packages.
  pmd-net-addr = self.callPackage ./pmd-net-addr.nix { };
  pmd-net-proto = self.callPackage ./pmd-net-proto.nix { };
  pmd-pytcp = self.callPackage ./pmd-pytcp.nix { };

  # Local unpacking of iOS backups (`backup2 --unback`).
  pyiosbackup = self.callPackage ./pyiosbackup.nix { };

  # ASGIWebDAV (`<group> webdav`) and its static-file middleware.
  asgimiddlewarestaticfile = self.callPackage ./asgimiddlewarestaticfile.nix { };
  asgiwebdav = self.callPackage ./asgiwebdav.nix { };
}