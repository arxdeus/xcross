abstract interface class SdkArchiveLinksInterface {
  Future<void> createLinks(
    Map<String, String> links, {
    void Function(int done, int total)? onProgress,
  });
}
