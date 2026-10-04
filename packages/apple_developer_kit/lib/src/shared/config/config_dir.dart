import 'package:apple_developer_kit/host/shared/apple_host_services.dart';
import 'package:meta/meta.dart';

@internal
String xcrossConfigDir({required AppleHostServices hostServices}) =>
    hostServices.configDirectory;
