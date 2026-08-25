/// Enables Firebase's source products when its manifest is evaluated on a
/// non-macOS host.
///
/// The identifying comment scopes this patch to the Firebase manifest shape
/// that deliberately wraps Apple-only products in a host OS conditional.
String patchFirebaseManifestForCrossHost(String manifest) {
  if (!manifest.contains('name: "Firebase"') ||
      !manifest.contains(
        '// Add Apple-only products when building on macOS hosts.',
      )) {
    return manifest;
  }

  return manifest.replaceAllMapped(
    RegExp(
      r'^\s*#if os\(macOS\)\s*$\n'
      r'(?=\s*// Add Apple-only products when building on macOS hosts\.)'
      r'([\s\S]*?)^\s*#endif // os\(macOS\)\s*$',
      multiLine: true,
    ),
    (match) => match.group(1)!,
  );
}
