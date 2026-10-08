abstract interface class DeviceHostPolicy {
  String get installCommand;
  String get preparationDeniedMessage;
  String describeTunnelFailure(List<String> recent);
  String elevatedCommand(String arguments);
  Future<String?> resolvePipx();
  Future<bool> lockdownTunnelLooksAlive();
}
