import 'package:apple_developer_kit/src/adi/loader/loader.dart';
import 'package:apple_developer_kit/src/adi/loader/loader_windows.dart';
import 'package:apple_developer_kit/src/host/linux/adi/linux_native_library_loader.dart';
import 'package:apple_developer_kit/src/host/macos/adi/macos_native_library_loader.dart';

NativeLibraryLoader createLinuxNativeLibraryLoader() =>
    LinuxNativeLibraryLoader();
NativeLibraryLoader createMacOSNativeLibraryLoader() =>
    MacOSNativeLibraryLoader();
NativeLibraryLoader createWindowsNativeLibraryLoader() =>
    WindowsNativeLibraryLoader();
