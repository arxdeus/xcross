abstract final class DartDefines {
  /// Adds the selected flavor while preserving explicit app-flavor overrides.
  static List<String> withFlavor(List<String> defines, String? flavor) => [
    ...defines,
    if (flavor != null &&
        !defines.any((define) => define.startsWith('FLUTTER_APP_FLAVOR=')))
      'FLUTTER_APP_FLAVOR=$flavor',
  ];
}
