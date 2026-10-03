import 'package:cli_kit/src/shared/platform/platform_host.dart';
import 'package:path/path.dart' as p;

final class PosixPaths implements HostPathsInterface {
  PosixPaths({
    Map<String, String> environment = const {},
    String currentDirectory = '.',
    String temporaryDirectory = '.',
    p.Context? context,
  }) : context =
           context ??
           p.Context(style: p.Style.posix, current: currentDirectory),
       temporaryRoot = temporaryDirectory,
       _environment = Map.unmodifiable(environment);
  final Map<String, String> _environment;
  @override
  final p.Context context;
  @override
  final String temporaryRoot;
  String get _home =>
      _environment['HOME'] ?? _environment['USERPROFILE'] ?? '.';
  @override
  String get configRoot =>
      _nonempty(_environment['XDG_CONFIG_HOME']) ??
      context.join(_home, '.config');
  @override
  String get cacheRoot =>
      _nonempty(_environment['XDG_CACHE_HOME']) ??
      context.join(_home, '.cache');
  @override
  String ioPath(String path) => context.isAbsolute(path)
      ? path
      : '${context.current}${context.current.endsWith('/') ? '' : '/'}$path';
  @override
  String executableName(String name, {String extension = '.exe'}) => name;
  @override
  String pathKey(String path) => context.normalize(context.absolute(path));
  String? _nonempty(String? value) =>
      value == null || value.isEmpty ? null : value;
}
