import 'package:cli_kit/shared/platform/platform_host.dart';
import 'package:path/path.dart' as p;

final class WindowsPaths implements HostPathsInterface {
  WindowsPaths({
    Map<String, String> environment = const {},
    String currentDirectory = '.',
    String temporaryDirectory = '.',
    p.Context? context,
  }) : context =
           context ??
           p.Context(style: p.Style.windows, current: currentDirectory),
       temporaryRoot = temporaryDirectory,
       _environment = Map.unmodifiable(environment);
  final Map<String, String> _environment;
  @override
  final p.Context context;
  @override
  final String temporaryRoot;
  String get _home => _value('USERPROFILE') ?? _value('HOME') ?? '.';
  String? _value(String key) {
    for (final entry in _environment.entries) {
      if (entry.key.toUpperCase() == key && entry.value.isNotEmpty) {
        return entry.value;
      }
    }
    return null;
  }

  @override
  String get configRoot =>
      _value('APPDATA') ??
      _value('XDG_CONFIG_HOME') ??
      context.join(_home, '.config');
  @override
  String get cacheRoot =>
      _value('LOCALAPPDATA') ??
      _value('XDG_CACHE_HOME') ??
      context.join(_home, '.cache');
  @override
  String ioPath(String path) {
    if (path.startsWith(_prefix)) return path;
    final absolute = context.normalize(context.absolute(path));
    if (absolute.startsWith(r'\\')) {
      return '$_uncPrefix${absolute.substring(2)}';
    }
    return '$_prefix$absolute';
  }

  @override
  String executableName(String name, {String extension = '.exe'}) {
    final existing = context.extension(name).toLowerCase();
    final recognized = {
      extension.toLowerCase(),
      '.exe',
      '.cmd',
      '.bat',
      '.com',
    };
    return recognized.contains(existing) ? name : '$name$extension';
  }

  @override
  String pathKey(String path) =>
      context.normalize(context.absolute(path)).toLowerCase();
  static const _prefix = r'\\?\';
  static const _uncPrefix = r'\\?\UNC\';
}
