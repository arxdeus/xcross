// MIT License
//
// Copyright (c) 2021 Lenny Erik Schneider
// Copyright (c) 2026 xcross contributors
//
// Based on https://github.com/lennyerik/windows-anisette (MIT), reduced to
// one machine-readable AOSKit OTP operation for xcross. Apple DLLs are loaded
// from the user's own website-edition iTunes/iCloud installation and are not
// distributed with xcross.

#if defined(_WIN32)
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0602
#endif
#include <Windows.h>

#include <iostream>
#include <string>

namespace {
using ObjcId = void*;
using Selector = void*;
using GetClass = ObjcId(__cdecl*)(const char*);
using RegisterSelector = Selector(__cdecl*)(const char*);
using MessageSend = ObjcId(__cdecl*)();

std::wstring environment(const wchar_t* name) {
  const DWORD length = GetEnvironmentVariableW(name, nullptr, 0);
  if (length == 0) return {};
  std::wstring value(length, L'\0');
  GetEnvironmentVariableW(name, &value[0], length);
  value.resize(length - 1);
  return value;
}

std::wstring absolutePath(const std::wstring& path) {
  const DWORD length = GetFullPathNameW(path.c_str(), 0, nullptr, nullptr);
  if (length == 0) return path;
  std::wstring result(length, L'\0');
  const DWORD written =
      GetFullPathNameW(path.c_str(), length, &result[0], nullptr);
  if (written == 0 || written >= length) return path;
  result.resize(written);
  return result;
}

std::wstring appleRoot() {
  auto override = environment(L"XCROSS_APPLE_COMMON_FILES");
  if (!override.empty()) return absolutePath(override);
  auto common = environment(L"CommonProgramFiles(x86)");
  if (common.empty()) common = L"C:\\Program Files (x86)\\Common Files";
  return absolutePath(common + L"\\Apple");
}

bool fileExists(const std::wstring& path) {
  const DWORD attributes = GetFileAttributesW(path.c_str());
  return attributes != INVALID_FILE_ATTRIBUTES &&
         !(attributes & FILE_ATTRIBUTE_DIRECTORY);
}

bool hasSupportFrameworks(const std::wstring& directory) {
  return fileExists(directory + L"\\objc.dll") &&
         fileExists(directory + L"\\Foundation.dll");
}

std::string windowsError(DWORD code) {
  // ASCII by design: Dart decodes child stderr as UTF-8, while FormatMessageA
  // uses the active Windows code page and can corrupt localized diagnostics.
  return "Windows error " + std::to_string(code);
}

std::string escapeJson(const char* value) {
  std::string out;
  for (const unsigned char ch : std::string(value == nullptr ? "" : value)) {
    switch (ch) {
      case '\\': out += "\\\\"; break;
      case '"': out += "\\\""; break;
      case '\b': out += "\\b"; break;
      case '\f': out += "\\f"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (ch < 0x20) {
          const char hex[] = "0123456789abcdef";
          out += "\\u00";
          out += hex[ch >> 4];
          out += hex[ch & 0x0f];
        } else {
          out += static_cast<char>(ch);
        }
    }
  }
  return out;
}
}  // namespace

int main() {
  SetErrorMode(GetErrorMode() | SEM_FAILCRITICALERRORS |
               SEM_NOGPFAULTERRORBOX | SEM_NOOPENFILEERRORBOX);

  const std::wstring root = appleRoot();
  std::wstring support = root + L"\\Apple Application Support";
  if (!hasSupportFrameworks(support)) {
    support = root + L"\\Mobile Device Support";
  }
  const std::wstring internet = root + L"\\Internet Services";
  if (!hasSupportFrameworks(support)) {
    std::cerr << "Could not find Apple support objc.dll and Foundation.dll. "
                 "Install the website edition of iTunes: "
              << windowsError(ERROR_FILE_NOT_FOUND);
    return 2;
  }
  if (!fileExists(internet + L"\\AOSKit.dll")) {
    std::cerr << "Could not find Apple Internet Services AOSKit.dll. Install "
                 "the website edition of iCloud: "
              << windowsError(ERROR_FILE_NOT_FOUND);
    return 2;
  }
  constexpr DWORD searchFlags = LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR |
                                LOAD_LIBRARY_SEARCH_USER_DIRS |
                                LOAD_LIBRARY_SEARCH_SYSTEM32;

  if (!SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_USER_DIRS |
                                LOAD_LIBRARY_SEARCH_SYSTEM32)) {
    const DWORD error = GetLastError();
    std::cerr << "Could not secure the DLL search path: "
              << windowsError(error);
    return 2;
  }
  const DLL_DIRECTORY_COOKIE supportCookie = AddDllDirectory(support.c_str());
  const DLL_DIRECTORY_COOKIE internetCookie = AddDllDirectory(internet.c_str());
  if (supportCookie == nullptr || internetCookie == nullptr) {
    const DWORD error = GetLastError();
    if (internetCookie != nullptr) RemoveDllDirectory(internetCookie);
    if (supportCookie != nullptr) RemoveDllDirectory(supportCookie);
    std::cerr << "Could not register Apple DLL directories: "
              << windowsError(error);
    return 2;
  }
  const auto removeDllDirectories = [&]() {
    RemoveDllDirectory(internetCookie);
    RemoveDllDirectory(supportCookie);
  };
  SetCurrentDirectoryW(support.c_str());

  HMODULE objc = LoadLibraryExW(
      (support + L"\\objc.dll").c_str(), nullptr, searchFlags);
  if (objc == nullptr) {
    const DWORD error = GetLastError();
    std::cerr << "Could not load Apple Application Support objc.dll: "
              << windowsError(error);
    removeDllDirectories();
    return 2;
  }
  HMODULE foundation = LoadLibraryExW(
      (support + L"\\Foundation.dll").c_str(), nullptr, searchFlags);
  if (foundation == nullptr) {
    const DWORD error = GetLastError();
    std::cerr << "Could not load Apple Application Support Foundation.dll: "
              << windowsError(error);
    FreeLibrary(objc);
    removeDllDirectories();
    return 3;
  }
  HMODULE aoskit = LoadLibraryExW(
      (internet + L"\\AOSKit.dll").c_str(), nullptr, searchFlags);
  if (aoskit == nullptr) {
    const DWORD error = GetLastError();
    std::cerr << "Could not load Apple Internet Services AOSKit.dll. Install "
                 "the website edition of iCloud: "
              << windowsError(error);
    FreeLibrary(foundation);
    FreeLibrary(objc);
    removeDllDirectories();
    return 4;
  }

  auto getClass = reinterpret_cast<GetClass>(GetProcAddress(objc, "objc_getClass"));
  auto registerSelector = reinterpret_cast<RegisterSelector>(
      GetProcAddress(objc, "sel_registerName"));
  auto send = reinterpret_cast<MessageSend>(GetProcAddress(objc, "objc_msgSend"));
  if (getClass == nullptr || registerSelector == nullptr || send == nullptr) {
    std::cerr << "Apple Objective-C runtime is missing required exports.";
    FreeLibrary(aoskit);
    FreeLibrary(foundation);
    FreeLibrary(objc);
    removeDllDirectories();
    return 5;
  }

  const auto makeString = [&](const char* value) -> ObjcId {
    const ObjcId stringClass = getClass("NSString");
    const Selector selector = registerSelector("stringWithUTF8String:");
    return reinterpret_cast<ObjcId(__cdecl*)(ObjcId, Selector, const char*)>(
        send)(stringClass, selector, value);
  };
  const auto describe = [&](ObjcId value) -> const char* {
    if (value == nullptr) return nullptr;
    const ObjcId description =
        reinterpret_cast<ObjcId(__cdecl*)(ObjcId, Selector)>(send)(
            value, registerSelector("description"));
    if (description == nullptr) return nullptr;
    return reinterpret_cast<const char*(__cdecl*)(ObjcId, Selector)>(send)(
        description, registerSelector("UTF8String"));
  };
  const auto dictionaryValue = [&](ObjcId dictionary,
                                   const char* key) -> ObjcId {
    return reinterpret_cast<ObjcId(__cdecl*)(ObjcId, Selector, ObjcId)>(send)(
        dictionary, registerSelector("objectForKey:"), makeString(key));
  };

  const ObjcId utilities = getClass("AOSUtilities");
  const ObjcId headers = utilities == nullptr
      ? nullptr
      : reinterpret_cast<ObjcId(__cdecl*)(ObjcId, Selector, ObjcId)>(send)(
            utilities, registerSelector("retrieveOTPHeadersForDSID:"),
            makeString("-2"));
  const char* otp = describe(dictionaryValue(headers, "X-Apple-MD"));
  const char* machine = describe(dictionaryValue(headers, "X-Apple-MD-M"));
  if (otp == nullptr || machine == nullptr || *otp == '\0' || *machine == '\0') {
    std::cerr << "AOSKit did not return machine OTP data. Start website-edition "
                 "iTunes and iCloud once, then retry.";
    FreeLibrary(aoskit);
    FreeLibrary(foundation);
    FreeLibrary(objc);
    removeDllDirectories();
    return 6;
  }

  const char* routing = describe(dictionaryValue(headers, "X-Apple-MD-RINFO"));
  if (routing == nullptr || *routing == '\0') {
    routing = describe(dictionaryValue(headers, "X-Apple-I-MD-RINFO"));
  }
  // ponytail: historical AOSKit compatibility value used by AltServer and
  // windows-anisette; remove once current Apple builds expose routing here.
  if (routing == nullptr || *routing == '\0') routing = "17106176";

  std::cout << "{\"oneTimePassword\":\"" << escapeJson(otp)
            << "\",\"machineIdentifier\":\"" << escapeJson(machine)
            << "\",\"routingInfo\":\"" << escapeJson(routing) << "\"}";

  FreeLibrary(aoskit);
  FreeLibrary(foundation);
  FreeLibrary(objc);
  removeDllDirectories();
  return 0;
}
#else
#include <iostream>

int main() {
  std::cerr << "xcross-aoskit is only supported on Windows.";
  return 1;
}
#endif
