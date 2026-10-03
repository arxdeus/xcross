abstract interface class DeviceConsole {
  Stream<void> get interrupts;
  bool get inputHasTerminal;
  bool get outputHasTerminal;
  bool get echoMode;
  set echoMode(bool value);
  bool get lineMode;
  set lineMode(bool value);
  String? readLine();
  void write(String value);
  void writeln(String value);
  void add(List<int> value);
}
