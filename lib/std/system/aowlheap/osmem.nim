# VENDORED from the heap library (p2b @ bff58a4): src/heap/osmem.nim.
# Do not edit here; change the heap repo and run tools/sync_aowlheap.sh.
## OS layer of the heap: virtual-range reservation (the cage), commit /
## decommit of pages, the native stack base, the conservative stack scan
## (callee-saved registers spilled into the scanned range) and a monotonic
## clock. Everything here is C behind `{.emit.}` because nimony cannot cast
## between pointers and procs, and because the stack scan must not be
## instrumented by AddressSanitizer (it reads other frames' redzones by design).
##
## The scan calls back into nimony through the exported symbol
## `heap_conservative_word` (defined in `heap/core.nim`), once per stack word
## that falls inside the cage (or, with NaN-box stripping, whose low 48 bits do).

{.emit: """
#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#ifdef _WIN32
#include <windows.h>
#else
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <sys/mman.h>
#include <unistd.h>
#include <pthread.h>
#include <time.h>
#include <link.h>
#include <stddef.h>
#endif

#if defined(__has_feature)
#  if __has_feature(address_sanitizer)
#    define HEAP_NO_ASAN __attribute__((no_sanitize_address))
#  endif
#endif
#ifndef HEAP_NO_ASAN
#  if defined(__SANITIZE_ADDRESS__)
#    define HEAP_NO_ASAN __attribute__((no_sanitize_address))
#  else
#    define HEAP_NO_ASAN
#  endif
#endif

/* Reserve `size` bytes of address space aligned to `align` (a power of two),
   inaccessible until committed. Returns 0 on failure. */
void* heap_os_reserve(int64_t size, int64_t align) {
#ifdef _WIN32
  /* over-reserve, then re-reserve exactly at the aligned address */
  for (int attempt = 0; attempt < 8; attempt++) {
    char* p = (char*)VirtualAlloc(NULL, (SIZE_T)(size + align), MEM_RESERVE, PAGE_NOACCESS);
    if (!p) return 0;
    uintptr_t a = ((uintptr_t)p + (uintptr_t)align - 1) & ~((uintptr_t)align - 1);
    VirtualFree(p, 0, MEM_RELEASE);
    void* q = VirtualAlloc((void*)a, (SIZE_T)size, MEM_RESERVE, PAGE_NOACCESS);
    if (q) return q;
  }
  return 0;
#else
  size_t total = (size_t)(size + align);
  char* p = (char*)mmap(NULL, total, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
  if (p == MAP_FAILED) return 0;
  uintptr_t a = ((uintptr_t)p + (uintptr_t)align - 1) & ~((uintptr_t)align - 1);
  size_t head = a - (uintptr_t)p;
  size_t tail = total - head - (size_t)size;
  if (head) munmap(p, head);
  if (tail) munmap((char*)a + size, tail);
  return (void*)a;
#endif
}

/* Reserve + make readable/writable lazily-backed memory (side tables). */
void* heap_os_reserve_rw(int64_t size) {
#ifdef _WIN32
  return VirtualAlloc(NULL, (SIZE_T)size, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
#else
  void* p = mmap(NULL, (size_t)size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
  return p == MAP_FAILED ? (void*)0 : p;
#endif
}

int64_t heap_os_release(void* p, int64_t size) {
#ifdef _WIN32
  (void)size; return VirtualFree(p, 0, MEM_RELEASE) ? 0 : -1;
#else
  return munmap(p, (size_t)size);
#endif
}

/* Make [p, p+size) readable+writable. Fresh commits read as zero. */
int64_t heap_os_commit(void* p, int64_t size) {
#ifdef _WIN32
  return VirtualAlloc(p, (SIZE_T)size, MEM_COMMIT, PAGE_READWRITE) ? 0 : -1;
#else
  return mprotect(p, (size_t)size, PROT_READ | PROT_WRITE);
#endif
}

/* Give the physical memory back; the range stays committed-on-touch and
   reads as zero afterwards. */
int64_t heap_os_discard(void* p, int64_t size) {
#ifdef _WIN32
  return VirtualAlloc(p, (SIZE_T)size, MEM_RESET, PAGE_READWRITE) ? (memset(p, 0, (size_t)size), 0) : -1;
#else
  return madvise(p, (size_t)size, MADV_DONTNEED);
#endif
}

/* Make a range inaccessible again (debug quarantine of freed large pages). */
int64_t heap_os_protect_none(void* p, int64_t size) {
#ifdef _WIN32
  DWORD old; return VirtualProtect(p, (SIZE_T)size, PAGE_NOACCESS, &old) ? 0 : -1;
#else
  return mprotect(p, (size_t)size, PROT_NONE);
#endif
}

/* Highest address of the calling thread's stack (stacks grow down). */
void* heap_os_stack_base(void) {
#ifdef _WIN32
  ULONG_PTR lo = 0, hi = 0;
  GetCurrentThreadStackLimits(&lo, &hi);
  return (void*)hi;
#else
  pthread_attr_t attr;
  void* addr = 0; size_t size = 0;
  if (pthread_getattr_np(pthread_self(), &attr) != 0) return 0;
  pthread_attr_getstack(&attr, &addr, &size);
  pthread_attr_destroy(&attr);
  return (char*)addr + size;
#endif
}

int64_t heap_os_now_ns(void) {
#ifdef _WIN32
  LARGE_INTEGER f, c; QueryPerformanceFrequency(&f); QueryPerformanceCounter(&c);
  return (int64_t)((double)c.QuadPart * 1e9 / (double)f.QuadPart);
#else
  struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
#endif
}

void heap_os_fatal(void* msg) {
  fprintf(stderr, "heap: fatal: %s\n", msg);
  fflush(stderr);
  abort();
}

/* The static data of the image (executable or shared library) that contains
   `addr`: its writable segments (.data, .bss, ...) are written to `out` as
   [lo, hi) pairs, at most `cap` pairs; returns the number found (-1: the
   image was not found). These are conservative root ranges for an embedder
   whose globals may hold heap pointers (nimony's `-d:aowlgc`). */
#ifndef _WIN32
typedef struct { uintptr_t addr; void** out; int64_t cap, n; int found;
                 void* tlsLo; void* tlsHi; } HeapImageQuery;

static int heap_image_cb(struct dl_phdr_info* info, size_t size, void* data) {
  HeapImageQuery* q = (HeapImageQuery*)data;
  int mine = 0;
  for (int i = 0; i < info->dlpi_phnum; i++) {
    const ElfW(Phdr)* ph = &info->dlpi_phdr[i];
    if (ph->p_type != PT_LOAD) continue;
    uintptr_t lo = info->dlpi_addr + ph->p_vaddr;
    if (q->addr >= lo && q->addr < lo + ph->p_memsz) { mine = 1; break; }
  }
  if (!mine) return 0;
  q->found = 1;
  for (int i = 0; i < info->dlpi_phnum; i++) {
    const ElfW(Phdr)* ph = &info->dlpi_phdr[i];
    if (ph->p_type == PT_LOAD && (ph->p_flags & PF_W)) {
      if (q->n < q->cap) {
        uintptr_t lo = info->dlpi_addr + ph->p_vaddr;
        q->out[2 * q->n] = (void*)lo;
        q->out[2 * q->n + 1] = (void*)(lo + ph->p_memsz);
      }
      q->n++;
    } else if (ph->p_type == PT_TLS &&
               size >= offsetof(struct dl_phdr_info, dlpi_tls_data) + sizeof(void*) &&
               info->dlpi_tls_data) {
      q->tlsLo = info->dlpi_tls_data;
      q->tlsHi = (char*)info->dlpi_tls_data + ph->p_memsz;
    }
  }
  return 1;
}
#endif

int64_t heap_os_image_ranges(void* addr, void** out, int64_t cap) {
#ifdef _WIN32
  HMODULE mod = 0;
  if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                          GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, (LPCWSTR)addr, &mod))
    return -1;
  char* base = (char*)mod;
  IMAGE_NT_HEADERS* nt = (IMAGE_NT_HEADERS*)(base + ((IMAGE_DOS_HEADER*)base)->e_lfanew);
  IMAGE_SECTION_HEADER* sec = IMAGE_FIRST_SECTION(nt);
  int64_t n = 0;
  for (int i = 0; i < nt->FileHeader.NumberOfSections; i++) {
    if (!(sec[i].Characteristics & IMAGE_SCN_MEM_WRITE)) continue;
    if (n < cap) {
      out[2 * n] = base + sec[i].VirtualAddress;
      out[2 * n + 1] = base + sec[i].VirtualAddress + sec[i].Misc.VirtualSize;
    }
    n++;
  }
  return n;
#else
  HeapImageQuery q = { (uintptr_t)addr, out, cap, 0, 0, 0, 0 };
  dl_iterate_phdr(heap_image_cb, &q);
  return q.found ? q.n : -1;
#endif
}

/* The calling thread's thread-local block of the image containing `addr`
   ([*lo, *hi), both 0 when it has none or it is not allocated yet). */
void heap_os_image_tls(void* addr, void** lo, void** hi) {
  *lo = 0; *hi = 0;
#ifdef _WIN32
  HMODULE mod = 0;
  if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                          GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, (LPCWSTR)addr, &mod))
    return;
  char* base = (char*)mod;
  IMAGE_NT_HEADERS* nt = (IMAGE_NT_HEADERS*)(base + ((IMAGE_DOS_HEADER*)base)->e_lfanew);
  IMAGE_DATA_DIRECTORY dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_TLS];
  if (dir.VirtualAddress == 0) return;
  IMAGE_TLS_DIRECTORY* td = (IMAGE_TLS_DIRECTORY*)(base + dir.VirtualAddress);
  DWORD idx = *(DWORD*)td->AddressOfIndex;
  void** slots = *(void***)((char*)NtCurrentTeb() + (sizeof(void*) == 8 ? 0x58 : 0x2C));
  if (!slots || !slots[idx]) return;
  *lo = slots[idx];
  *hi = (char*)slots[idx] + (td->EndAddressOfRawData - td->StartAddressOfRawData) + td->SizeOfZeroFill;
#else
  void* tmp[2];
  HeapImageQuery q = { (uintptr_t)addr, tmp, 0, 0, 0, 0, 0 };
  dl_iterate_phdr(heap_image_cb, &q);
  *lo = q.tlsLo; *hi = q.tlsHi;
#endif
}

void heap_conservative_word(void* ctx, void* w);

/* Scan [lo, hi) word by word. Words inside [cageLo, cageHi) are reported;
   when `mask` != 0, a word whose `w & mask` lies in the cage is reported
   stripped (NaN-boxed pointers). */
HEAP_NO_ASAN __attribute__((noinline))
void heap_scan_range(void* ctx, void* lo, void* hi, void* cageLo, void* cageHi, uint64_t mask) {
  uintptr_t a = ((uintptr_t)lo + 7) & ~(uintptr_t)7;
  uintptr_t e = (uintptr_t)hi & ~(uintptr_t)7;
  uintptr_t cl = (uintptr_t)cageLo, span = (uintptr_t)cageHi - (uintptr_t)cageLo;
  for (; a < e; a += 8) {
    uintptr_t w = *(volatile uintptr_t*)a;
    if (w - cl < span) heap_conservative_word(ctx, (void*)w);
    else if (mask) {
      uintptr_t s = w & (uintptr_t)mask;
      if (s - cl < span) heap_conservative_word(ctx, (void*)s);
    }
  }
}

/* Spill every callee-saved register into this frame, then scan from this
   frame up to the stack base. Caller-saved registers hold nothing live across
   the call that reached here (the C ABI guarantees the callers spilled them). */
HEAP_NO_ASAN __attribute__((noinline))
void heap_scan_stack(void* ctx, void* base, void* cageLo, void* cageHi, uint64_t mask) {
  uintptr_t regs[16];
  memset(regs, 0, sizeof(regs));
#if defined(__x86_64__) || defined(_M_X64)
  __asm__ volatile(
    "movq %%rbx, 0(%0)\n\t"
    "movq %%rbp, 8(%0)\n\t"
    "movq %%r12, 16(%0)\n\t"
    "movq %%r13, 24(%0)\n\t"
    "movq %%r14, 32(%0)\n\t"
    "movq %%r15, 40(%0)\n\t"
    "movq %%rdi, 48(%0)\n\t"   /* callee-saved on Win64 */
    "movq %%rsi, 56(%0)\n\t"
    "movq %%rsp, 64(%0)\n\t"
    : : "r"(regs) : "memory");
#elif defined(__aarch64__)
  __asm__ volatile(
    "stp x19, x20, [%0, #0]\n\t"
    "stp x21, x22, [%0, #16]\n\t"
    "stp x23, x24, [%0, #32]\n\t"
    "stp x25, x26, [%0, #48]\n\t"
    "stp x27, x28, [%0, #64]\n\t"
    "stp x29, x30, [%0, #80]\n\t"
    : : "r"(regs) : "memory");
#else
  __builtin_unwind_init();
#endif
  void* lo = (void*)regs;
  if ((uintptr_t)base > (uintptr_t)lo)
    heap_scan_range(ctx, lo, base, cageLo, cageHi, mask);
  __asm__ volatile("" : : "r"(regs) : "memory");
}

""".}

proc osReserve*(size, align: int): pointer {.importc: "heap_os_reserve".}
proc osReserveRW*(size: int): pointer {.importc: "heap_os_reserve_rw".}
proc osRelease*(p: pointer; size: int): int {.importc: "heap_os_release".}
proc osCommit*(p: pointer; size: int): int {.importc: "heap_os_commit".}
proc osDiscard*(p: pointer; size: int): int {.importc: "heap_os_discard".}
proc osProtectNone*(p: pointer; size: int): int {.importc: "heap_os_protect_none".}
proc osStackBase*(): pointer {.importc: "heap_os_stack_base".}
proc osNowNs*(): int64 {.importc: "heap_os_now_ns".}
proc osFatal(msg: pointer) {.importc: "heap_os_fatal".}
proc osScanRange*(ctx, lo, hi, cageLo, cageHi: pointer; mask: uint64) {.importc: "heap_scan_range".}
proc osScanStack*(ctx, base, cageLo, cageHi: pointer; mask: uint64) {.importc: "heap_scan_stack".}
proc osImageRanges*(addrInImage: pointer; output: ptr UncheckedArray[pointer]; cap: int): int {.importc: "heap_os_image_ranges".}
proc osImageTls*(addrInImage: pointer; lo, hi: ptr pointer) {.importc: "heap_os_image_tls".}

proc fatal*(msg: string) {.noreturn.} =
  ## Unrecoverable heap error (corruption, cage exhaustion with no handler).
  var m = msg
  osFatal(cast[pointer](toCString(m)))
  panic(msg)
