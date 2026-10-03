abstract interface class DeviceHostPolicy {
  String get installCommand;
  String elevatedCommand(String arguments);
  Future<String?> resolvePipx();
  Future<bool> lockdownTunnelLooksAlive();
}
