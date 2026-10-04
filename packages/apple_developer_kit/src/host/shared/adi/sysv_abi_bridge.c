// SysV <-> Microsoft x64 calling-convention trampolines for loading
// Android/bionic ELF libraries on Windows.
//
// Both SysV and MS x64 require: on function ENTRY, rsp % 16 == 8
// (call pushed the return address). Equivalently, just BEFORE a call,
// rsp % 16 == 0. Getting this wrong makes callees' `movdqa [rbp-…]`
// faults (seen as c0000005 inside libstoreservicescore).
//
// Also: rdi/rsi are MS non-volatile / SysV arg regs → import saves them.
// MS callees may scribble 32 bytes of shadow space → export allocates it.

#include <stdint.h>
#include <string.h>

#if defined(_WIN32) && (defined(_M_X64) || defined(__x86_64__))

#include <windows.h>

typedef struct {
  uint8_t code[256];
  void* target;
} TrampolineSlot;

enum { kPoolCapacity = 512 };

static TrampolineSlot g_pool[kPoolCapacity];
static size_t g_pool_used = 0;
static int g_pool_executable = 0;

static int ensure_pool_executable(void) {
  if (g_pool_executable) return 1;
  DWORD old = 0;
  if (!VirtualProtect(g_pool, sizeof(g_pool), PAGE_EXECUTE_READWRITE, &old)) {
    return 0;
  }
  g_pool_executable = 1;
  return 1;
}

static TrampolineSlot* alloc_slot(void* target) {
  if (!ensure_pool_executable()) return NULL;
  if (g_pool_used >= kPoolCapacity) return NULL;
  TrampolineSlot* slot = &g_pool[g_pool_used++];
  memset(slot, 0, sizeof(*slot));
  slot->target = target;
  return slot;
}

static size_t emit_load_target(uint8_t* code, size_t at, const TrampolineSlot* slot) {
  const intptr_t rip_after = (intptr_t)(code + at + 7);
  const intptr_t target_addr = (intptr_t)&slot->target;
  const int32_t disp = (int32_t)(target_addr - rip_after);
  code[at++] = 0x48;
  code[at++] = 0x8B;
  code[at++] = 0x05;
  memcpy(code + at, &disp, 4);
  return at + 4;
}

// SysV -> MS (export)
static void emit_export(TrampolineSlot* slot, int argc) {
  uint8_t* code = slot->code;
  size_t at = 0;

  if (argc <= 4) {
    // Entry rsp≡8. Need rsp≡0 before call → sub 0x28 (shadow 0x20 + 8 pad).
    code[at++] = 0x48;
    code[at++] = 0x83;
    code[at++] = 0xEC;
    code[at++] = 0x28;

    if (argc >= 3) {
      code[at++] = 0x49;
      code[at++] = 0x89;
      code[at++] = 0xD2;
    }
    if (argc >= 4) {
      code[at++] = 0x49;
      code[at++] = 0x89;
      code[at++] = 0xCB;
    }
    if (argc >= 1) {
      code[at++] = 0x48;
      code[at++] = 0x89;
      code[at++] = 0xF9;
    }
    if (argc >= 2) {
      code[at++] = 0x48;
      code[at++] = 0x89;
      code[at++] = 0xF2;
    }
    if (argc >= 3) {
      code[at++] = 0x4D;
      code[at++] = 0x89;
      code[at++] = 0xD0;
    }
    if (argc >= 4) {
      code[at++] = 0x4D;
      code[at++] = 0x89;
      code[at++] = 0xD9;
    }

    at = emit_load_target(code, at, slot);
    code[at++] = 0xFF;
    code[at++] = 0xD0;
    code[at++] = 0x48;
    code[at++] = 0x83;
    code[at++] = 0xC4;
    code[at++] = 0x28;
    code[at++] = 0xC3;
    return;
  }

  // argc 5..8
  code[at++] = 0x41;
  code[at++] = 0x54; // push r12 ; entry≡8 → ≡0
  code[at++] = 0x41;
  code[at++] = 0x55; // push r13 ; → ≡8
  code[at++] = 0x4D;
  code[at++] = 0x89;
  code[at++] = 0xC4;
  if (argc >= 6) {
    code[at++] = 0x4D;
    code[at++] = 0x89;
    code[at++] = 0xCD;
  }
  if (argc >= 3) {
    code[at++] = 0x49;
    code[at++] = 0x89;
    code[at++] = 0xD2;
  }
  if (argc >= 4) {
    code[at++] = 0x49;
    code[at++] = 0x89;
    code[at++] = 0xCB;
  }
  code[at++] = 0x48;
  code[at++] = 0x89;
  code[at++] = 0xF9;
  code[at++] = 0x48;
  code[at++] = 0x89;
  code[at++] = 0xF2;
  if (argc >= 3) {
    code[at++] = 0x4D;
    code[at++] = 0x89;
    code[at++] = 0xD0;
  }
  if (argc >= 4) {
    code[at++] = 0x4D;
    code[at++] = 0x89;
    code[at++] = 0xD9;
  }

  // rsp≡8 after pushes. Need ≡0 before call ⇒ subtract N where N≡8 (mod 16).
  const int extra = argc - 4;
  int frame = 0x20 + 8 * extra;
  while ((frame & 0xF) != 0x8) {
    frame += 8;
  }

  code[at++] = 0x48;
  code[at++] = 0x81;
  code[at++] = 0xEC;
  memcpy(code + at, &frame, 4);
  at += 4;

  code[at++] = 0x4C;
  code[at++] = 0x89;
  code[at++] = 0x64;
  code[at++] = 0x24;
  code[at++] = 0x20;
  if (argc >= 6) {
    code[at++] = 0x4C;
    code[at++] = 0x89;
    code[at++] = 0x6C;
    code[at++] = 0x24;
    code[at++] = 0x28;
  }
  if (argc >= 7) {
    // entry arg7 @ [rsp+8]; after 2 pushes + frame: +0x10+frame
    const int off = frame + 0x18;
    code[at++] = 0x48;
    code[at++] = 0x8B;
    code[at++] = 0x84;
    code[at++] = 0x24;
    memcpy(code + at, &off, 4);
    at += 4;
    code[at++] = 0x48;
    code[at++] = 0x89;
    code[at++] = 0x44;
    code[at++] = 0x24;
    code[at++] = 0x30;
  }
  if (argc >= 8) {
    const int off = frame + 0x20;
    code[at++] = 0x48;
    code[at++] = 0x8B;
    code[at++] = 0x84;
    code[at++] = 0x24;
    memcpy(code + at, &off, 4);
    at += 4;
    code[at++] = 0x48;
    code[at++] = 0x89;
    code[at++] = 0x44;
    code[at++] = 0x24;
    code[at++] = 0x38;
  }

  at = emit_load_target(code, at, slot);
  code[at++] = 0xFF;
  code[at++] = 0xD0;
  code[at++] = 0x48;
  code[at++] = 0x81;
  code[at++] = 0xC4;
  memcpy(code + at, &frame, 4);
  at += 4;
  code[at++] = 0x41;
  code[at++] = 0x5D;
  code[at++] = 0x41;
  code[at++] = 0x5C;
  code[at++] = 0xC3;
  (void)at;
}

// MS -> SysV (import)
static void emit_import(TrampolineSlot* slot, int argc) {
  uint8_t* code = slot->code;
  size_t at = 0;

  // Entry rsp≡8 (Dart MS call). Save MS non-volatiles.
  code[at++] = 0x57; // push rdi ; ≡0
  code[at++] = 0x56; // push rsi ; ≡8
  // Before SysV call need rsp≡0 → one more 8-byte adjust.

  if (argc <= 4) {
    if (argc >= 4) {
      code[at++] = 0x4D;
      code[at++] = 0x89;
      code[at++] = 0xCB;
    }
    if (argc >= 3) {
      code[at++] = 0x4D;
      code[at++] = 0x89;
      code[at++] = 0xC2;
    }
    if (argc >= 1) {
      code[at++] = 0x48;
      code[at++] = 0x89;
      code[at++] = 0xCF;
    }
    if (argc >= 2) {
      code[at++] = 0x48;
      code[at++] = 0x89;
      code[at++] = 0xD6;
    }
    if (argc >= 3) {
      code[at++] = 0x4C;
      code[at++] = 0x89;
      code[at++] = 0xD2;
    }
    if (argc >= 4) {
      code[at++] = 0x4C;
      code[at++] = 0x89;
      code[at++] = 0xD9;
    }

    code[at++] = 0x48;
    code[at++] = 0x83;
    code[at++] = 0xEC;
    code[at++] = 0x08; // ≡0 before call
    at = emit_load_target(code, at, slot);
    code[at++] = 0xFF;
    code[at++] = 0xD0;
    code[at++] = 0x48;
    code[at++] = 0x83;
    code[at++] = 0xC4;
    code[at++] = 0x08;
    code[at++] = 0x5E;
    code[at++] = 0x5F;
    code[at++] = 0xC3;
    return;
  }

  code[at++] = 0x41;
  code[at++] = 0x54; // push r12 ; from ≡8 → ≡0
  code[at++] = 0x41;
  code[at++] = 0x55; // push r13 ; → ≡8
  // 4 pushes from entry≡8 → still ≡8. Need ≡0 before call.

  // MS arg5 on entry @[rsp+0x28]; after 4 pushes (+0x20) → @[rsp+0x48]
  code[at++] = 0x4C;
  code[at++] = 0x8B;
  code[at++] = 0x64;
  code[at++] = 0x24;
  code[at++] = 0x48;
  if (argc >= 6) {
    code[at++] = 0x4C;
    code[at++] = 0x8B;
    code[at++] = 0x6C;
    code[at++] = 0x24;
    code[at++] = 0x50;
  }

  code[at++] = 0x4D;
  code[at++] = 0x89;
  code[at++] = 0xCB;
  code[at++] = 0x4D;
  code[at++] = 0x89;
  code[at++] = 0xC2;
  code[at++] = 0x48;
  code[at++] = 0x89;
  code[at++] = 0xCF;
  code[at++] = 0x48;
  code[at++] = 0x89;
  code[at++] = 0xD6;
  code[at++] = 0x4C;
  code[at++] = 0x89;
  code[at++] = 0xD2;
  code[at++] = 0x4C;
  code[at++] = 0x89;
  code[at++] = 0xD9;
  code[at++] = 0x4D;
  code[at++] = 0x89;
  code[at++] = 0xE0;
  if (argc >= 6) {
    code[at++] = 0x4D;
    code[at++] = 0x89;
    code[at++] = 0xE9;
  }

  // Stack args for 7/8 plus align. Currently ≡8; need ≡0 before call
  // ⇒ subtract N with N ≡ 8 (mod 16).
  int aligned = 8;
  if (argc >= 8) {
    aligned = 24; // 16 bytes of args + 8 pad
  } else if (argc >= 7) {
    aligned = 8; // arg7 lives in the alignment slot at [rsp]
  }

  code[at++] = 0x48;
  code[at++] = 0x83;
  code[at++] = 0xEC;
  code[at++] = (uint8_t)aligned;

  if (argc >= 7) {
    // after 4 pushes (+0x20) + aligned: entry arg7 @0x38 → 0x58+aligned
    const int arg7_off = 0x58 + aligned;
    code[at++] = 0x48;
    code[at++] = 0x8B;
    code[at++] = 0x84;
    code[at++] = 0x24;
    memcpy(code + at, &arg7_off, 4);
    at += 4;
    code[at++] = 0x48;
    code[at++] = 0x89;
    code[at++] = 0x04;
    code[at++] = 0x24;
  }
  if (argc >= 8) {
    const int arg8_off = 0x60 + aligned;
    code[at++] = 0x48;
    code[at++] = 0x8B;
    code[at++] = 0x84;
    code[at++] = 0x24;
    memcpy(code + at, &arg8_off, 4);
    at += 4;
    code[at++] = 0x48;
    code[at++] = 0x89;
    code[at++] = 0x44;
    code[at++] = 0x24;
    code[at++] = 0x08;
  }

  at = emit_load_target(code, at, slot);
  code[at++] = 0xFF;
  code[at++] = 0xD0;
  code[at++] = 0x48;
  code[at++] = 0x83;
  code[at++] = 0xC4;
  code[at++] = (uint8_t)aligned;
  code[at++] = 0x41;
  code[at++] = 0x5D;
  code[at++] = 0x41;
  code[at++] = 0x5C;
  code[at++] = 0x5E;
  code[at++] = 0x5F;
  code[at++] = 0xC3;
  (void)at;
}

__declspec(dllexport) void* provision_sysv_wrap_export(void* ms_fn, int argc) {
  if (ms_fn == NULL || argc < 0 || argc > 8) return NULL;
  TrampolineSlot* slot = alloc_slot(ms_fn);
  if (slot == NULL) return NULL;
  emit_export(slot, argc);
  FlushInstructionCache(GetCurrentProcess(), slot->code, sizeof(slot->code));
  return slot->code;
}

__declspec(dllexport) void* provision_sysv_wrap_import(void* sysv_fn, int argc) {
  if (sysv_fn == NULL || argc < 0 || argc > 8) return NULL;
  TrampolineSlot* slot = alloc_slot(sysv_fn);
  if (slot == NULL) return NULL;
  emit_import(slot, argc);
  FlushInstructionCache(GetCurrentProcess(), slot->code, sizeof(slot->code));
  return slot->code;
}

#else

#if defined(_WIN32)
__declspec(dllexport)
#endif
void* provision_sysv_wrap_export(void* fn, int argc) {
  (void)argc;
  return fn;
}

#if defined(_WIN32)
__declspec(dllexport)
#endif
void* provision_sysv_wrap_import(void* fn, int argc) {
  (void)argc;
  return fn;
}

#endif
