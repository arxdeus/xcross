import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mobile_device/dart_mobile_device.dart';
import 'package:dds/dap.dart';
import 'package:frontend_server_kit/frontend_server_kit.dart';
import 'package:path/path.dart' as p;
import 'package:pure/pure.dart';
import 'package:vm_service/vm_service.dart' as vm;
import 'package:xcross/src/constants.dart';
import 'package:xcross/src/package_config_resolver.dart';

/// Spawns `xcross flutter run` and drives it: keypresses on its stdin for
/// hot reload/restart/quit, plus a Dart VM Service connection (via
/// [DartDebugAdapter]) for breakpoints/stepping/stack/variables.
final class XcrossDap
    extends
        DartDebugAdapter<
          DartLaunchRequestArguments,
          DartAttachRequestArguments
        > {
  XcrossDap(ByteStreamServerChannel channel) : super(channel) {
    channel.closed.then((_) => _quitChild());
  }

  @override
  final parseLaunchArgs = DartLaunchRequestArguments.fromJson;
  @override
  final parseAttachArgs = DartAttachRequestArguments.fromJson;

  @override
  bool get supportsRestartRequest => true;

  @override
  bool get terminateOnVmServiceClose => false;

  Process? _child;
  String _pendingLine = '';
  bool _vmServiceReported = false;
  PackageUris? _packageUris;

  /// Re-keys breakpoints from local file paths to `package:` URIs, which
  /// bind more reliably than plain file URIs.
  @override
  Uri? convertUriToOrgDartlangSdk(Uri input) =>
      super.convertUriToOrgDartlangSdk(input) ??
      (input.isScheme('file') ? _packageUris?.toPackageUri(input) : null);

  @override
  Future<void> debuggerConnected(vm.VM vmInfo) async {}

  @override
  Future<void> attachImpl() =>
      throw UnimplementedError('xcross dap only supports launch requests.');

  @override
  Future<void> launchImpl() =>
      throw UnsupportedError('Call launchAndRespond() instead.');

  @override
  Future<void> launchAndRespond(void Function() sendResponse) async {
    final launchArgs = args as DartLaunchRequestArguments;
    final cwd = launchArgs.cwd ?? Directory.current.path;
    await _prepareUriMappings(cwd);
    await _warnIfTunnelUnreachable();

    final child = await _startRun(launchArgs, cwd);
    _child = child;
    _pipeChildOutput(child);
    unawaited(
      child.exitCode.then((code) {
        handleSessionExited(code);
        handleSessionTerminate();
      }),
    );

    sendResponse();
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

  Future<void> _warnIfTunnelUnreachable() async {
    final reachable = await TunnelDaemon.isReachable().timeout(
      const Duration(seconds: 5),
      onTimeout: nullaryFalse,
    );
    if (reachable) return;
    sendOutput(
      'stderr',
      'xcross: the iOS 17+ RSD tunnel daemon is not reachable — falling '
          'back to the userspace tunnel over usbmux.\n'
          'For the faster kernel tunnel, run `xcross tunnel` once in a '
          'terminal (it needs sudo/Administrator).\n',
    );
  }

  Future<Process> _startRun(DartLaunchRequestArguments launchArgs, String cwd) {
    final program = launchArgs.program;
    final target = p.isAbsolute(program)
        ? p.relative(program, from: cwd)
        : program;
    return Process.start(
      Platform.resolvedExecutable,
      ['flutter', 'run', '--target', target, ...?launchArgs.args],
      workingDirectory: cwd,
      environment: const {'XCROSS_DAP': '1'},
    );
  }

  void _pipeChildOutput(Process child) {
    child.stdin.done.ignore();
    child.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(_onChildStdout, onError: _childError);
    child.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((text) => sendOutput('stderr', text), onError: _childError);
  }

  Future<void> _prepareUriMappings(String cwd) async {
    final packageConfig = await PackageConfigResolver.require(cwd);
    _packageUris ??= await PackageUris.load(packageConfig);
    orgDartlangSdkMappings.clear();
  }

  void _childError(Object e) =>
      sendOutput('stderr', 'xcross dap: child stream error: $e\n');

  void _onChildStdout(String text) {
    sendOutput('stdout', text);
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
        unawaited(connectDebugger(Uri.parse(uri)));
      }
      return;
    }
  }

  /// Handles Dart-Code's `hotReload`/`hotRestart` toolbar commands.
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

  /// The debug toolbar's Restart button — a hot restart, not a relaunch.
  @override
  Future<void> restartRequest(
    Request request,
    RestartArguments? args,
    void Function() sendResponse,
  ) async {
    _writeKey('R');
    sendResponse();
  }

  Future<void> _quitChild() async {
    _writeKey('q');
    await _reapChild();
  }

  @override
  Future<void> disconnectImpl() => _quitChild();

  @override
  Future<void> terminateImpl() => _quitChild();

  Future<void> _reapChild() async {
    final child = _child;
    if (child == null) return;
    _child = null;
    if (await _exited(child, const Duration(seconds: 5))) return;
    child.kill();
    if (await _exited(child, const Duration(seconds: 2))) return;
    child.kill(ProcessSignal.sigkill);
  }

  Future<bool> _exited(Process child, Duration within) =>
      child.exitCode.then(unaryTrue).timeout(within, onTimeout: nullaryFalse);

  void _writeKey(String key) {
    try {
      _child?.stdin.add(utf8.encode(key));
    } on Object catch (_) {}
  }
}
