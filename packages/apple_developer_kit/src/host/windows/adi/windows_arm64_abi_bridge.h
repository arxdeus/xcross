#include <windows.h>
#include <stddef.h>
#include <limits.h>

#if defined(_M_ARM64EC) || defined(__arm64ec__)
#error ARM64EC is not a supported Android AAPCS64 host
#endif

typedef LONG (WINAPI *Arm64Random)(void*, unsigned char*, ULONG, ULONG);

typedef struct {
  void* host_teb;
  void* shadow_top;
  uintptr_t tls[8];
} Arm64ThreadState;

typedef char Arm64TlsOffsetCheck[offsetof(Arm64ThreadState, tls) == 16 ? 1 : -1];

static INIT_ONCE g_arm64_once = INIT_ONCE_STATIC_INIT;
static DWORD g_arm64_fls = FLS_OUT_OF_INDEXES;
static Arm64Random g_arm64_random = NULL;
static volatile LONG g_arm64_slots = 0;
static volatile LONG g_arm64_veneer_pages = 0;

enum {
  kArm64ContextSize = 65536,
  kArm64PageSize = 4096,
  kArm64PoolCapacity = 512,
  kArm64MaximumCodeSize = 64 * 1024 * 1024,
  kArm64MaximumTlsReads = 65536,
  kArm64MaximumVeneerPages = 4096
};

static VOID CALLBACK arm64_free_thread(PVOID context) {
  if (context != NULL) VirtualFree(context, 0, MEM_RELEASE);
}

static BOOL CALLBACK arm64_initialize(PINIT_ONCE once, PVOID parameter,
                                      PVOID* context) {
  SYSTEM_INFO info;
  HMODULE bcrypt;
  (void)once;
  (void)parameter;
  (void)context;
  GetSystemInfo(&info);
  if (info.dwAllocationGranularity != kArm64ContextSize ||
      info.dwPageSize != kArm64PageSize) return FALSE;
  bcrypt = LoadLibraryExW(L"bcrypt.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
  if (bcrypt == NULL) return FALSE;
  g_arm64_random = (Arm64Random)GetProcAddress(bcrypt, "BCryptGenRandom");
  if (g_arm64_random == NULL) {
    FreeLibrary(bcrypt);
    return FALSE;
  }
  g_arm64_fls = FlsAlloc(arm64_free_thread);
  if (g_arm64_fls == FLS_OUT_OF_INDEXES) {
    FreeLibrary(bcrypt);
    g_arm64_random = NULL;
    return FALSE;
  }
  return TRUE;
}

static void* arm64_enter(void* host_teb) {
  Arm64ThreadState* state;
  if (!InitOnceExecuteOnce(&g_arm64_once, arm64_initialize, NULL, NULL)) {
    RaiseFailFastException(NULL, NULL, 0);
    return NULL;
  }
  state = (Arm64ThreadState*)FlsGetValue(g_arm64_fls);
  if (state == NULL) {
    state = (Arm64ThreadState*)VirtualAlloc(NULL, kArm64ContextSize,
                                          MEM_RESERVE, PAGE_NOACCESS);
    if (state == NULL ||
        VirtualAlloc(state, kArm64PageSize,
                     MEM_COMMIT, PAGE_READWRITE) == NULL ||
        VirtualAlloc((uint8_t*)state + 2 * kArm64PageSize,
                     kArm64ContextSize - 3 * kArm64PageSize,
                     MEM_COMMIT, PAGE_READWRITE) == NULL) {
      if (state != NULL) VirtualFree(state, 0, MEM_RELEASE);
      RaiseFailFastException(NULL, NULL, 0);
      return NULL;
    }
    state->shadow_top = (uint8_t*)state + 2 * kArm64PageSize;
    if (g_arm64_random(NULL, (unsigned char*)&state->tls[5],
                       sizeof(state->tls[5]), 2) < 0 ||
        state->tls[5] == 0 || !FlsSetValue(g_arm64_fls, state)) {
      VirtualFree(state, 0, MEM_RELEASE);
      RaiseFailFastException(NULL, NULL, 0);
      return NULL;
    }
  }
  state->host_teb = host_teb;
  return state->shadow_top;
}

static void arm64_emit_address(uint32_t* code, size_t* at, uintptr_t address) {
  code[(*at)++] = 0xd2800010u | ((uint32_t)(address & 0xffff) << 5);
  code[(*at)++] = 0xf2a00010u | ((uint32_t)((address >> 16) & 0xffff) << 5);
  code[(*at)++] = 0xf2c00010u | ((uint32_t)((address >> 32) & 0xffff) << 5);
  code[(*at)++] = 0xf2e00010u | ((uint32_t)((address >> 48) & 0xffff) << 5);
}

static void* arm64_publish(const uint32_t* code, size_t size) {
  uint32_t* allocation;
  DWORD old;
  if (InterlockedIncrement(&g_arm64_slots) > kArm64PoolCapacity) {
    InterlockedDecrement(&g_arm64_slots);
    return NULL;
  }
  allocation = (uint32_t*)VirtualAlloc(NULL, size, MEM_RESERVE | MEM_COMMIT,
                                      PAGE_READWRITE);
  if (allocation == NULL) {
    InterlockedDecrement(&g_arm64_slots);
    return NULL;
  }
  memcpy(allocation, code, size);
  if (!VirtualProtect(allocation, size, PAGE_EXECUTE_READ, &old) ||
      !FlushInstructionCache(GetCurrentProcess(), allocation, size)) {
    VirtualFree(allocation, 0, MEM_RELEASE);
    InterlockedDecrement(&g_arm64_slots);
    return NULL;
  }
  return allocation;
}

__declspec(dllexport) void* provision_sysv_wrap_import(void* function, int argc) {
  static const uint32_t save[] = {
    0xd103c3ff, 0xa90d7bfd, 0x910343fd, 0xf90073f2,
    0xa90007e0, 0xa9010fe2, 0xa90217e4, 0xa9031fe6,
    0xad0207e0, 0xad030fe2, 0xad0417e4, 0xad051fe6,
    0xf90063e8, 0xaa1203e0
  };
  static const uint32_t restore[] = {
    0xd63f0200, 0xaa0003f2,
    0xa94007e0, 0xa9410fe2, 0xa94217e4, 0xa9431fe6,
    0xad4207e0, 0xad430fe2, 0xad4417e4, 0xad451fe6,
    0xf94063e8
  };
  static const uint32_t finish[] = {
    0xd63f0200, 0x9270be50, 0xf9000612, 0xf94073f2,
    0xa94d7bfd, 0x9103c3ff, 0xd65f03c0
  };
  uint32_t code[64];
  size_t at;
  if (function == NULL || argc < 0 || argc > 8) return NULL;
  memcpy(code, save, sizeof(save));
  at = sizeof(save) / sizeof(*save);
  arm64_emit_address(code, &at, (uintptr_t)arm64_enter);
  memcpy(code + at, restore, sizeof(restore));
  at += sizeof(restore) / sizeof(*restore);
  arm64_emit_address(code, &at, (uintptr_t)function);
  memcpy(code + at, finish, sizeof(finish));
  at += sizeof(finish) / sizeof(*finish);
  return arm64_publish(code, at * sizeof(*code));
}

__declspec(dllexport) void* provision_sysv_wrap_export(void* function, int argc) {
  static const uint32_t save[] = {
    0xd10083ff, 0xa9007bfd, 0x910003fd, 0xf9000bf2,
    0x9270be50, 0xf9000612, 0xf9400212
  };
  static const uint32_t finish[] = {
    0xd63f0200, 0xf9400bf2, 0xa9407bfd, 0x910083ff, 0xd65f03c0
  };
  uint32_t code[32];
  size_t at;
  if (function == NULL || argc < 0 || argc > 8) return NULL;
  memcpy(code, save, sizeof(save));
  at = sizeof(save) / sizeof(*save);
  arm64_emit_address(code, &at, (uintptr_t)function);
  memcpy(code + at, finish, sizeof(finish));
  at += sizeof(finish) / sizeof(*finish);
  return arm64_publish(code, at * sizeof(*code));
}

static int arm64_branch(uintptr_t from, uintptr_t to, uint32_t* instruction) {
  const int64_t displacement = (int64_t)to - (int64_t)from;
  if ((displacement & 3) != 0 || displacement < -134217728 ||
      displacement > 134217724) return 0;
  *instruction = 0x14000000u | ((uint32_t)(displacement / 4) & 0x03ffffffu);
  return 1;
}

static uint32_t* arm64_allocate_near(uintptr_t start, size_t length,
                                    size_t veneer_size) {
  const uintptr_t base = start & ~(uintptr_t)(kArm64ContextSize - 1);
  const LONG pages = (LONG)((veneer_size + kArm64PageSize - 1) / kArm64PageSize);
  uintptr_t distance;
  if (InterlockedAdd(&g_arm64_veneer_pages, pages) > kArm64MaximumVeneerPages) {
    InterlockedAdd(&g_arm64_veneer_pages, -pages);
    return NULL;
  }
  for (distance = kArm64ContextSize; distance < 134217728;
       distance += kArm64ContextSize) {
    int direction;
    for (direction = 0; direction < 2; direction++) {
      uintptr_t address;
      uint32_t ignored;
      uint32_t* result;
      if (direction == 0) {
        if (base > UINTPTR_MAX - distance) continue;
        address = base + distance;
      } else {
        if (base < distance) continue;
        address = base - distance;
      }
      if (address == 0 || address > UINTPTR_MAX - veneer_size ||
          !arm64_branch(start, address + veneer_size - 4, &ignored) ||
          !arm64_branch(start + length - 4, address, &ignored)) continue;
      result = (uint32_t*)VirtualAlloc((void*)address, veneer_size,
                                     MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
      if (result != NULL) return result;
    }
  }
  InterlockedAdd(&g_arm64_veneer_pages, -pages);
  return NULL;
}

static void arm64_release_veneers(uint32_t* veneers, size_t size) {
  const LONG pages = (LONG)((size + kArm64PageSize - 1) / kArm64PageSize);
  VirtualFree(veneers, 0, MEM_RELEASE);
  InterlockedAdd(&g_arm64_veneer_pages, -pages);
}

__declspec(dllexport) int32_t provision_windows_arm64_prepare_code(
    void* address, size_t length) {
  uint32_t* code = (uint32_t*)address;
  uint32_t* veneers;
  size_t count = 0;
  size_t index;
  size_t next = 0;
  size_t veneer_size;
  DWORD old;
  if (address == NULL || ((uintptr_t)address & 3) != 0 || (length & 3) != 0 ||
      length > kArm64MaximumCodeSize ||
      (uintptr_t)address > UINTPTR_MAX - length) return -1;
  for (index = 0; index < length / sizeof(*code); index++) {
    const uint32_t instruction = code[index];
    if ((instruction & 0xffffffe0u) == 0xd51bd040u) return -1;
    if ((instruction & 0xffffffe0u) == 0xd53bd040u) {
      const unsigned reg = instruction & 31;
      if (reg == 18 || reg == 31 || ++count > kArm64MaximumTlsReads) return -1;
    }
  }
  if (count == 0) return 0;
  veneer_size = count * 3 * sizeof(*veneers);
  veneers = arm64_allocate_near((uintptr_t)address, length, veneer_size);
  if (veneers == NULL) return -1;
  for (index = 0; index < length / sizeof(*code); index++) {
    if ((code[index] & 0xffffffe0u) == 0xd53bd040u) {
      const unsigned reg = code[index] & 31;
      uint32_t branch;
      if (!arm64_branch((uintptr_t)&code[index], (uintptr_t)&veneers[next],
                        &branch) ||
          !arm64_branch((uintptr_t)&veneers[next + 2],
                        (uintptr_t)&code[index + 1], &veneers[next + 2])) {
        arm64_release_veneers(veneers, veneer_size);
        return -1;
      }
      veneers[next] = 0x9270be40u | reg;
      veneers[next + 1] = 0x91004000u | (reg << 5) | reg;
      next += 3;
    }
  }
  if (!VirtualProtect(veneers, veneer_size, PAGE_EXECUTE_READ, &old) ||
      !FlushInstructionCache(GetCurrentProcess(), veneers, veneer_size)) {
    arm64_release_veneers(veneers, veneer_size);
    return -1;
  }
  next = 0;
  for (index = 0; index < length / sizeof(*code); index++) {
    if ((code[index] & 0xffffffe0u) == 0xd53bd040u) {
      uint32_t branch;
      arm64_branch((uintptr_t)&code[index], (uintptr_t)&veneers[next], &branch);
      code[index] = branch;
      next += 3;
    }
  }
  if (!FlushInstructionCache(GetCurrentProcess(), address, length)) {
    arm64_release_veneers(veneers, veneer_size);
    return -1;
  }
  return (int32_t)count;
}
