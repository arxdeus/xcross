// STDOUT DISCIPLINE — invariants for everything in this file:
//  1. [ByteStreamServerChannel] (package:dds) owns stdout framing — it's the
//     ONLY thing here that touches stdout. A stray byte desynchronises the
//     frame stream for good.
//  2. Never call Log.logStatus() on the DAP code path — it writes to fd1. logWarn /
//     logError go to fd2 and are safe, but an `output` event is better.
//  3. Never start a child with ProcessStartMode.inheritStdio from this process.
//     `xcross flutter run` spawns ~9 grandchildren that write straight to fd1,
//     which is exactly why it runs as a piped child process instead of inline.
//     The tunneld pre-flight must use TunnelDaemon.isReachable() (pure HTTP),
//     never ensureRunning() (reaches Sudo.cacheCredentials -> inheritStdio).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dds/dap.dart';
import 'package:path/path.dart' as p;
import 'package:vm_service/vm_service.dart' as vm;
import 'package:xcross/src/constants.dart';
import 'package:xcross/src/device/tunnel_daemon.dart';
import 'package:xcross/src/util/package_uris.dart';

/// `xcross dap` — Debug Adapter Protocol server driving `xcross flutter run`.
///
/// Spawned by `.vscode/xcross_dap.dart` (see `xcross vscode`), which VS Code
/// launches through `dart.customFlutterDapPath`.
class DapCommand extends Command<void> {
  @override
  String get name => 'dap';

  @override
  String get description =>
      'Debug Adapter Protocol server for the VS Code Run & Debug buttons.';

  @override
  bool get hidden => true;

  @override
  Future<void> run() {
    final channel = ByteStreamServerChannel(stdin, stdout, null);
    XcrossDap(channel);
    return channel.closed;
  }
}

/// A DAP debug adapter that spawns `xcross flutter run` and drives it:
///
///  - `r`/`R`/`q` keypresses on its stdin for hot reload/restart/quit (the
///    same protocol [SessionConsole] speaks for the interactive CLI).
///  - a second, independent connection to the app's Dart VM Service — set up
///    by [DartDebugAdapter.connectDebugger] once the child prints the VM
///    Service URI — for real breakpoints/stepping/stack/variables. All of
///    that logic (breakpoint sync, pause/resume, stack frames, evaluate) is
///    already implemented by [DartDebugAdapter]; this class only needs to
///    hand it a URI and translate the toolbar buttons.
class XcrossDap
    extends
        DartDebugAdapter<
          DartLaunchRequestArguments,
          DartAttachRequestArguments
        > {
  XcrossDap(ByteStreamServerChannel channel) : super(channel) {
    // Fallback for a pipe that just closes (editor force-quit, crash) without
    // an explicit disconnect/terminate request. [DartDebugAdapter.shutdown]
    // already runs on channel-close to notify the client, but does not reap
    // our child — do that here too. Idempotent with [disconnectImpl] /
    // [terminateImpl], which normally get there first (this is a no-op then).
    channel.closed.then((_) => _quitChild());
  }

  @override
  final parseLaunchArgs = DartLaunchRequestArguments.fromJson;
  @override
  final parseAttachArgs = DartAttachRequestArguments.fromJson;

  @override
  bool get supportsRestartRequest => true;

  // Our own child's exitCode (below) is what ends the session; a hot restart
  // recycles isolates on the SAME VM Service connection, so treating its
  // (temporary) hiccups as session-ending here would be wrong.
  @override
  bool get terminateOnVmServiceClose => false;

  Process? _child;
  // Holds an unterminated line across stdout chunks: the vm-service marker
  // and its URI can straddle an arbitrary chunk boundary.
  String _pendingLine = '';
  bool _vmServiceReported = false;
  PackageUris? _packageUris;

  /// Re-keys breakpoints from local file paths to `package:` URIs.
  ///
  /// `ThreadInfo.resolvePathToUri` consults this hook first, so whatever it
  /// returns becomes the `scriptUri` of `addBreakpointWithScriptUri` — see
  /// [PackageUris] for why the `package:` form is the one that reliably binds.
  /// SDK mappings keep priority; files with no package equivalent (`test/`,
  /// `bin/`) fall through and keep plain file-URI behaviour.
  @override
  Uri? convertUriToOrgDartlangSdk(Uri input) =>
      super.convertUriToOrgDartlangSdk(input) ??
      (input.isScheme('file') ? _packageUris?.toPackageUri(input) : null);

  @override
  Future<void> debuggerConnected(vm.VM vmInfo) async {}

  @override
  Future<void> attachImpl() =>
      throw UnimplementedError('xcross dap only supports launch requests.');

  // launchAndRespond (below) drives the whole launch instead, so it can send
  // the DAP response before the async `flutter.appStart` event — see its
  // comment. DartCliDebugAdapter in package:dds does the same for the same
  // reason.
  @override
  Future<void> launchImpl() =>
      throw UnsupportedError('Call launchAndRespond() instead.');

  @override
  Future<void> launchAndRespond(void Function() sendResponse) async {
    final launchArgs = args as DartLaunchRequestArguments;
    final cwd = launchArgs.cwd ?? Directory.current.path;
    await _prepareUriMappings(cwd);

    // With tunneld down the child reaches `sudo -v` under inheritStdio and can
    // block forever on a tty nobody can see. Warn, but let the run command
    // report the device-specific failure. A half-dead tunneld can accept the
    // socket and never answer, hence the timeout.
    final tunnelUp = await TunnelDaemon.isReachable().timeout(
      const Duration(seconds: 5),
      onTimeout: () => false,
    );
    if (!tunnelUp) {
      sendOutput(
        'stderr',
        'xcross: the iOS 17+ RSD tunnel daemon is not reachable — falling '
            'back to the userspace tunnel over usbmux.\n'
            'For the faster kernel tunnel, run `xcross prepare` once in a '
            'terminal (it needs sudo/Administrator).\n',
      );
    }

    // NEVER forward Dart-Code's `toolArgs`: it injects `-d <deviceId>` and
    // --host-vmservice-port, which conflict with xcross device resolution. Only
    // the user's own `args` from launch.json is passed through.
    final program = launchArgs.program;
    final target = p.isAbsolute(program)
        ? p.relative(program, from: cwd)
        : program;
    final extraArgs = launchArgs.args ?? const <String>[];

    final child = await Process.start(
      Platform.resolvedExecutable,
      ['flutter', 'run', '--target', target, ...extraArgs],
      workingDirectory: cwd,
      // Tells SessionConsole that a controller owns its stdin pipe, so EOF
      // there means "editor gone, quit" instead of "no keyboard" (CI, docker
      // without -i). Parent env is still inherited.
      environment: const {'XCROSS_DAP': '1'},
    );
    _child = child;
    // The child may die first; a broken-pipe write reports asynchronously here
    // and would otherwise kill the adapter mid-shutdown.
    child.stdin.done.ignore();
    // Utf8Decoder as a transformer carries a multi-byte sequence across chunk
    // boundaries; utf8.decode() per chunk replaces it with U+FFFD.
    child.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(_onChildStdout, onError: _childError);
    child.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((text) => sendOutput('stderr', text), onError: _childError);
    // Registered before the response so a child that dies instantly cannot
    // leave a zombie session in the editor.
    unawaited(
      child.exitCode.then((code) {
        handleSessionExited(code);
        handleSessionTerminate();
      }),
    );

    sendResponse();
    // flutter.appStart populates Dart-Code's session state (flutterMode,
    // deviceId, hasStarted) that the Hot Reload/Restart toolbar and DevTools
    // auto-launch key off; flutter.appStarted (sent once the app is actually
    // up, in _onChildStdout below) is its counterpart.
    sendEvent(
      RawEventBody({
        'appId': 'xcross',
        'deviceId': 'ios',
        'mode': 'debug',
        'supportsRestart': true,
      }),
      eventType: 'flutter.appStart',
    );
  }

  /// Loads the package mapping [convertUriToOrgDartlangSdk] needs, and drops
  /// the bogus SDK mapping the base class computed.
  ///
  /// [DartDebugAdapter] takes its SDK root from `Platform.resolvedExecutable`,
  /// assuming it runs on the Dart VM. `xcross dap` is an AOT binary, so that
  /// resolves to e.g. `/usr/local`; with an unlucky install prefix it would
  /// rewrite user-code breakpoint URIs into `org-dartlang-sdk:` ones matching
  /// no script. Dropping it costs only local SDK-source navigation, which was
  /// already broken — `sourceRequest` still serves those from the VM.
  Future<void> _prepareUriMappings(String cwd) async {
    _packageUris ??= await PackageUris.load(
      p.join(cwd, '.dart_tool', 'package_config.json'),
    );
    orgDartlangSdkMappings.clear();
  }

  void _childError(Object e) =>
      sendOutput('stderr', 'xcross dap: child stream error: $e\n');

  void _onChildStdout(String text) {
    sendOutput('stdout', text);
    // Stop reassembling lines once the URI is known: nothing else is parsed.
    if (_vmServiceReported) return;
    final lines = (_pendingLine + text).split('\n');
    _pendingLine = lines.removeLast();
    for (final line in lines) {
      final start = line.indexOf(DeviceConstants.vmServiceMarker);
      if (start < 0) continue;
      _vmServiceReported = true;
      sendEvent(RawEventBody(const {}), eventType: 'flutter.appStarted');
      final uri = line
          .substring(start + DeviceConstants.vmServiceMarker.length)
          .trim();
      if (uri.isNotEmpty) {
        // Connects our OWN VM Service client (independent of the child's,
        // which it uses for hot reload) and turns on breakpoints/stepping/
        // stack/variables/evaluate — all implemented by DartDebugAdapter.
        // It also emits the `dart.debuggerUris` event for DevTools once
        // connected, so no need to send that ourselves.
        unawaited(connectDebugger(Uri.parse(uri)));
      }
      return;
    }
  }

  /// `hotReload`/`hotRestart` are Dart-Code's custom Flutter toolbar
  /// commands; everything else (updateDebugOptions, updateSendLogsToClient,
  /// callService, ...) is already handled by [DartDebugAdapter.customRequest].
  @override
  Future<void> customRequest(
    Request request,
    RawRequestArguments? args,
    void Function(Object?) sendResponse,
  ) async {
    switch (request.command) {
      case 'hotReload':
        _writeKey('r');
        sendResponse(null);
      case 'hotRestart':
        _writeKey('R');
        sendResponse(null);
      default:
        await super.customRequest(request, args, sendResponse);
    }
  }

  /// Standard DAP restart (the debug toolbar's Restart button, gated on
  /// [supportsRestartRequest]) — a hot restart, not a process relaunch.
  @override
  Future<void> restartRequest(
    Request request,
    RestartArguments? args,
    void Function() sendResponse,
  ) async {
    _writeKey('R');
    sendResponse();
  }

  /// `q` first so [SessionConsole] runs its real cleanup (frontend_server,
  /// device session, tunneld), then escalate.
  Future<void> _quitChild() async {
    _writeKey('q');
    await _reapChild();
  }

  @override
  Future<void> disconnectImpl() => _quitChild();

  @override
  Future<void> terminateImpl() => _quitChild();

  // ponytail: signals only the direct child. `xcross flutter run` spawns its
  // build-phase grandchildren (clang, pub, and other tools) with inheritStdio,
  // so those survive a disconnect mid-build. Needs a process group (no portable
  // setsid on macOS) if that becomes a real problem.
  Future<void> _reapChild() async {
    final child = _child;
    if (child == null) return;
    _child = null;
    await child.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        child.kill();
        return child.exitCode.timeout(
          const Duration(seconds: 2),
          onTimeout: () {
            child.kill(ProcessSignal.sigkill);
            return -1;
          },
        );
      },
    );
  }

  void _writeKey(String key) {
    try {
      _child?.stdin.add(utf8.encode(key));
    } on Object catch (_) {
      // Child already gone; nothing to steer.
    }
  }
}
