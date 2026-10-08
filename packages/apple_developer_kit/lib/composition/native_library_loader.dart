import 'package:apple_developer_kit/host/shared/adi/loader/loader.dart';
import 'package:apple_developer_kit/src/host/linux/adi/linux_native_library_loader.dart';
import 'package:apple_developer_kit/src/host/macos/adi/macos_native_library_loader.dart';
import 'package:apple_developer_kit/src/host/windows/adi/loader/loader_windows.dart';

@pragma('vm:entry-point')
NativeLibraryLoader createLinuxNativeLibraryLoader() =>
    LinuxNativeLibraryLoader();
@pragma('vm:entry-point')
NativeLibraryLoader createMacOSNativeLibraryLoader() =>
    MacOSNativeLibraryLoader();
@pragma('vm:entry-point')
NativeLibraryLoader createWindowsNativeLibraryLoader() =>
    WindowsNativeLibraryLoader();
