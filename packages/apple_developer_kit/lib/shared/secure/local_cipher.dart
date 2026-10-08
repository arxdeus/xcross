/// Local-at-rest encryption for credential files, keyed to this machine
/// and this user account.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:apple_developer_kit/host/shared/apple_host_services.dart';
import 'package:apple_developer_kit/shared/errors/errors.dart';
import 'package:apple_developer_kit/src/shared/config/config_dir.dart';
import 'package:apple_developer_kit/src/shared/secure/local_cipher.dart';
import 'package:apple_developer_kit/src/shared/secure/secure_file.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:pointycastle/export.dart' as pc;

/// Raised when a sealed file cannot be opened with this machine's key.
final class LocalCipherError extends AppleError {
  const LocalCipherError(super.message);
}

/// AES-256-GCM for the files xcross keeps under [xcrossConfigDir].
///
/// ## Threat model — read this before extending it
///
/// The key is **not** a shared secret compiled into the binary. xcross
/// ships public release binaries, so any constant baked into them is
/// public too, and an attacker who can read your config directory can
/// read the binary just as easily. Such a key would be obfuscation
/// dressed up as encryption.
///
/// Instead the key is derived per install:
///
///   `key = HKDF-SHA256(ikm: <key file>, salt: <machine id>, info: v1)`
///
/// * the *key file* is 32 random bytes in [defaultKeyFilePath], mode 600,
///   generated on first use — so it is scoped to this user account;
/// * the *machine id* (`/etc/machine-id`, macOS `IOPlatformUUID`,
///   Windows `MachineGuid`) is not on disk in the config directory at all
///   — so copying the directory elsewhere yields undecryptable files.
///
/// What this buys: a config directory that leaks through a backup, a
/// synced dotfiles folder, an accidental `git add`, or a stray archive is
/// inert on any other machine. What it does **not** buy: protection from
/// code already running as you, which can simply read the key file. Only
/// an OS keychain with a user-presence prompt defends against that.
///
/// Losing the key file (or moving to a new machine) makes sealed files
/// unreadable, so only *re-obtainable* material may be sealed — a login
/// session you can fetch again by re-authenticating. Never seal state
/// that cannot be regenerated, such as the Anisette provisioning
/// `routingInfo`.
///
/// ## Stability across upgrades
///
/// Nothing in the derivation comes from the xcross binary, so installing a
/// new version — release tarball, `pub global activate`, or a self-update —
/// leaves sealed files readable: installers only replace the install root,
/// never [xcrossConfigDir]. What *does* invalidate them is a new machine, a
/// wiped config directory, or a regenerated machine id; hosts where the
/// last one happens routinely (containers, ephemeral CI images) should set
/// [bindingEnvironmentVariable] to `key-only`.
final class LocalCipher {
  /// [machineId] overrides machine-id detection; intended for tests. Pass
  /// `''` to simulate a host that exposes none.
  LocalCipher({
    required AppleHostServices hostServices,
    String? keyFilePath,
    String? machineId,
  }) : hostServices = hostServices,
       keyFilePath =
           keyFilePath ?? defaultKeyFilePath(hostServices: hostServices),
       _machineIdOverride = machineId;

  final AppleHostServices hostServices;

  /// `<config>/xcross/local.key`.
  @useResult
  static String defaultKeyFilePath({required AppleHostServices hostServices}) =>
      p.join(xcrossConfigDir(hostServices: hostServices), 'local.key');

  final String keyFilePath;
  final String? _machineIdOverride;

  /// Derived once per process per binding: both the key file read and the
  /// machine-id lookup (a subprocess on macOS/Windows) are too costly to
  /// repeat.
  final Map<LocalCipherBinding, Future<Uint8List>> _keys = {};
  Future<String>? _machineIdCache;

  static const int _keyBytes = 32;
  static const int _nonceBytes = 12; // GCM standard; do not change.
  static const int _macBits = 128;
  static const String _envelopeMarker = 'xcrossSealed';
  static const int _envelopeVersion = 1;
  static const String _kdfInfo = 'xcross.local-cipher.v1';

  /// Opts out of machine binding, for containers and CI images where the
  /// machine id is regenerated on every run. Set it to `key-only` and the
  /// config directory becomes portable together with its key file.
  static const String bindingEnvironmentVariable = 'XCROSS_SESSION_BINDING';

  /// Encrypts [plaintext] into a self-describing JSON envelope.
  ///
  /// The envelope records *which* binding was used, so [open] never has to
  /// guess. That matters more than it looks: if the binding were implicit,
  /// a machine-id lookup that succeeded when sealing but failed later
  /// (a sandbox denying `ioreg`, a container without `/etc/machine-id`)
  /// would silently derive a different key and destroy the session.
  Future<String> seal(String plaintext) async {
    final binding = await _bindingForSealing();
    final nonce = SecureFile.randomBytes(_nonceBytes);
    final cipher = _gcm(await _keyFor(binding), nonce, forEncryption: true);
    final sealed = cipher.process(utf8.encode(plaintext));
    return jsonEncode({
      _envelopeMarker: _envelopeVersion,
      'alg': 'AES-256-GCM',
      'kdf': 'HKDF-SHA256',
      'bind': binding.wireName,
      'nonce': base64.encode(nonce),
      'data': base64.encode(sealed),
    });
  }

  /// Reverses [seal].
  ///
  /// Throws [LocalCipherError] when the envelope is malformed or when the
  /// authentication tag does not verify — which is what a config
  /// directory copied from another machine looks like.
  Future<String> open(String envelope) async {
    final Object? doc;
    try {
      doc = jsonDecode(envelope);
    } on FormatException {
      throw const LocalCipherError('sealed data is not valid JSON');
    }
    if (doc is! Map || doc[_envelopeMarker] != _envelopeVersion) {
      throw const LocalCipherError('unrecognised sealed-data envelope');
    }

    final Uint8List nonce;
    final Uint8List data;
    try {
      nonce = base64.decode(doc['nonce']! as String);
      data = base64.decode(doc['data']! as String);
    } on Object {
      throw const LocalCipherError('sealed data is corrupt');
    }
    if (nonce.length != _nonceBytes) {
      throw const LocalCipherError('sealed data has an invalid nonce');
    }

    // Envelopes predating the `bind` field were always machine-bound.
    final binding = LocalCipherBinding.byWireName(
      doc['bind'] ?? LocalCipherBinding.machine.wireName,
    );
    if (binding == null) {
      throw const LocalCipherError('sealed data uses an unknown key binding');
    }

    final cipher = _gcm(await _keyFor(binding), nonce, forEncryption: false);
    final Uint8List plaintext;
    try {
      plaintext = cipher.process(data);
    } on pc.InvalidCipherTextException {
      throw const LocalCipherError(
        'sealed data does not belong to this machine or user account '
        '(authentication failed)',
      );
    }
    return utf8.decode(plaintext);
  }

  /// Whether [contents] looks like output of [seal], as opposed to a
  /// legacy plaintext file that still needs migrating.
  @useResult
  static bool isSealed(String contents) {
    final Object? doc;
    try {
      doc = jsonDecode(contents);
    } on FormatException {
      return false;
    }
    return doc is Map && doc[_envelopeMarker] == _envelopeVersion;
  }

  static pc.GCMBlockCipher _gcm(
    Uint8List key,
    Uint8List nonce, {
    required bool forEncryption,
  }) => pc.GCMBlockCipher(pc.AESEngine())
    ..init(
      forEncryption,
      pc.AEADParameters(
        pc.KeyParameter(key),
        _macBits,
        nonce,
        utf8.encode(_kdfInfo),
      ),
    );

  /// Machine binding unless the host cannot supply a stable id, or the
  /// operator opted out via [bindingEnvironmentVariable].
  Future<LocalCipherBinding> _bindingForSealing() async {
    final requested =
        hostServices.host.environment.values[bindingEnvironmentVariable];
    if (requested != null && requested.trim().isNotEmpty) {
      final binding = LocalCipherBinding.byWireName(requested.trim());
      if (binding == null) {
        throw LocalCipherError(
          '$bindingEnvironmentVariable must be one of '
          '${LocalCipherBinding.values.map((b) => b.wireName).join(', ')}',
        );
      }
      if (binding == LocalCipherBinding.keyOnly) return binding;
    }
    return (await _machineIdValue()).isEmpty
        ? LocalCipherBinding.keyOnly
        : LocalCipherBinding.machine;
  }

  Future<Uint8List> _keyFor(LocalCipherBinding binding) =>
      _keys[binding] ??= _deriveKey(binding);

  Future<Uint8List> _deriveKey(LocalCipherBinding binding) async {
    final ikm = await _readOrCreateKeyFile();
    var machineId = '';
    if (binding == LocalCipherBinding.machine) {
      machineId = await _machineIdValue();
      if (machineId.isEmpty) {
        throw const LocalCipherError(
          'this data is bound to a machine identifier that is no longer '
          'readable here',
        );
      }
    }
    final salt = pc.SHA256Digest().process(
      utf8.encode('${binding.wireName}\u0000$machineId'),
    );
    final derivator = pc.HKDFKeyDerivator(pc.SHA256Digest())
      ..init(pc.HkdfParameters(ikm, _keyBytes, salt, utf8.encode(_kdfInfo)));
    final out = Uint8List(_keyBytes);
    derivator.deriveKey(null, 0, out, 0);
    return out;
  }

  /// Reads the key file, creating it on first use.
  ///
  /// The create path deliberately re-reads after writing: two xcross
  /// processes racing on first use must converge on one key rather than
  /// each keeping the one it generated.
  Future<Uint8List> _readOrCreateKeyFile() async {
    final file = hostServices.host.fileSystem.file(keyFilePath);
    if (!file.existsSync()) {
      await SecureFile(hostServices: hostServices).writeString(
        keyFilePath,
        base64.encode(SecureFile.randomBytes(_keyBytes)),
      );
    } else {
      SecureFile(hostServices: hostServices).harden(keyFilePath);
    }

    final Uint8List key;
    try {
      key = base64.decode((await file.readAsString()).trim());
    } on Object {
      throw LocalCipherError('$keyFilePath: corrupt key file');
    }
    if (key.length != _keyBytes) {
      throw LocalCipherError('$keyFilePath: corrupt key file');
    }
    return key;
  }

  Future<String> _machineIdValue() {
    final override = _machineIdOverride;
    if (override != null) return Future.value(override);
    return _machineIdCache ??= hostServices.machineIdentity.read();
  }
}
