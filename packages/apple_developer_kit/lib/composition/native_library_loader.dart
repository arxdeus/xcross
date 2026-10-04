import 'package:apple_developer_kit/host/shared/adi/loader/loader.dart';
import 'package:apple_developer_kit/src/host/linux/adi/linux_native_library_loader.dart';
import 'package:apple_developer_kit/src/host/macos/adi/macos_native_library_loader.dart';
import 'package:apple_developer_kit/src/host/windows/adi/loader/loader_windows.dart';

NativeLibraryLoader createLinuxNativeLibraryLoader() =>
    LinuxNativeLibraryLoader();
NativeLibraryLoader createMacOSNativeLibraryLoader() =>
    MacOSNativeLibraryLoader();
NativeLibraryLoader createWindowsNativeLibraryLoader() =>
    WindowsNativeLibraryLoader();
