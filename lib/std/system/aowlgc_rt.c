/* aowlgc_rt.c -- the tracing heap behind nimony's `-d:aowlgc` memory mode.

   This is the P2 *shim*: the minimal heap the compiler integration needs,
   named after aowlvm DESIGN.md section 2 so it can be swapped for the `heap`
   library (agentwork/heap) without touching the compiler side. Interface used
   by generated code and lib/std/system/aowlgc.nim:

     void*  aowlgcNew(size, trace, fin)   zeroed object; type id from (trace, fin)
     void   aowlgcMark(env, p)            a precise edge (nil / non-heap ignored)
     void   aowlgcFree(p)                 explicit free (seq buffers, frames)
     size   aowlgcUsableSize(p)
     void*  aowlgcAllocPinned(size)       never collected, scanned conservatively
     void   aowlgcPin(p) / aowlgcUnpin(p) (GC_ref / GC_unref)
     void   aowlgcCollect(void)

   Model: one reserved virtual range of 64 KiB pages; small objects in
   size-class pages, large objects in page spans; non-moving. Every object has
   an 8-byte header {tid:16, flags:8, sc:8, pins:32} just before the pointer
   handed out. Mark: stop-the-world, explicit worklist. Roots: registers and
   the native stack (conservative), the executable's .data/.bss and its static
   TLS block (conservative), pinned objects. Sweep is two-phase: every dead
   object's finalizer runs before anything is freed, so a finalizer reading a
   (dead) buffer it owns never reads freed memory. Objects allocated during a
   collection are allocated black.

   Environment: AOWLGC_STRESS=N  collect every N allocations
                AOWLGC_VERIFY=1  after marking, check every precise edge of every
                                 live object points at a live object (abort if not)
                AOWLGC_POISON=1  fill freed memory with 0xDB (implied by STRESS)
                AOWLGC_STATS=1   print statistics at exit
   Linux/x86_64 + aarch64 (glibc) only for now. */

#if defined(_WIN32)
#  error "aowlgc shim: Windows roots (PE sections, TEB stack bounds) not implemented yet"
#endif

#ifndef _GNU_SOURCE
#  define _GNU_SOURCE
#endif
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <setjmp.h>
#include <sys/mman.h>
#include <pthread.h>
#include <link.h>

typedef void (*AgTraceFn)(void *box, void *env);
typedef void (*AgFinFn)(void *box);

#define AG_PAGE_SHIFT 16
#define AG_PAGE_SIZE ((size_t)1 << AG_PAGE_SHIFT)
#define AG_RESERVE ((size_t)64 << 30)              /* 64 GiB of address space */
#define AG_MAX_PAGES (AG_RESERVE >> AG_PAGE_SHIFT)
#define AG_HDR 8

enum { F_ALLOC = 1, F_MARK = 2, F_PINNED = 4, F_CONSERVATIVE = 8 };
enum { P_FREE = 0, P_SMALL = 1, P_LARGE = 2, P_CONT = 3 };

typedef struct {
  uint16_t tid;
  uint8_t flags;
  uint8_t sc;
  uint32_t pins;
} AgHeader;

typedef struct AgPage {
  uint8_t kind;
  uint8_t sc;
  uint32_t slotSize;
  uint32_t nslots;
  uint32_t bump;          /* slots [0, bump) have been handed out at least once */
  uint32_t used;
  uint32_t head;          /* P_CONT: index of the span's head page */
  size_t npages;          /* P_LARGE: span length */
  void *freeList;         /* freed slots (small pages) */
  struct AgPage *nextAvail;
  uint8_t inAvail;
} AgPage;

typedef struct {
  AgTraceFn trace;
  AgFinFn fin;
} AgTypeInfo;

static const uint32_t agSizeClasses[] = {
  16, 32, 48, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512,
  640, 768, 1024, 1280, 1536, 2048, 2560, 3072, 4096, 5120, 6144, 8192,
  10240, 12288, 16384, 21840, 32768
};
#define AG_NSC (sizeof(agSizeClasses) / sizeof(agSizeClasses[0]))
#define AG_MAX_SMALL 32768

/* All mutable state lives in one mmap'd block, NOT in .bss: .data/.bss are a
   conservative root range, and the heap's own pointers must not keep objects
   alive. Only `agS` itself (pointer to the mmap'd block, outside the heap) is
   a global. */
typedef struct {
  int inited;
  uint8_t *base;
  size_t top;                   /* pages [1, top) are in use; page 0 is never used */
  AgPage *pages;
  AgPage *avail[AG_NSC];
  /* free large spans: simple first-fit list of (first page, npages) */
  size_t *freeSpans;
  size_t nFreeSpans, capFreeSpans;
  /* types */
  AgTypeInfo *types;
  uint32_t ntypes, capTypes;
  uint32_t *typeHash;           /* open addressing: tid+1, 0 = empty */
  uint32_t hashCap;
  /* marking */
  AgHeader **work;
  size_t nwork, capWork;
  int inGc, inFinalizers, verifying;
  /* triggers */
  size_t bytesSinceGc, threshold, liveBytes;
  long stress, stressCount;
  int poison, verify, stats;
  /* roots */
  uint8_t *stackBase;
  uint8_t *tlsLo, *tlsHi;
  /* statistics */
  size_t collections, allocs, frees, finalized, verifiedEdges;
} AgState;

static AgState *agS;

extern char __data_start[], _end[];

static void agDie(const char *msg) {
  fprintf(stderr, "aowlgc: fatal: %s\n", msg);
  abort();
}

static void *agMap(size_t size) {
  void *p = mmap(NULL, size, PROT_READ | PROT_WRITE,
                 MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
  if (p == MAP_FAILED) agDie("cannot reserve address space");
  return p;
}

static void *agGrow(void *p, size_t *cap, size_t elem, size_t need) {
  if (need <= *cap) return p;
  size_t nc = *cap ? *cap * 2 : 256;
  while (nc < need) nc *= 2;
  void *q = realloc(p, nc * elem);
  if (!q) agDie("out of memory (gc metadata)");
  *cap = nc;
  return q;
}

static int agTlsCb(struct dl_phdr_info *info, size_t size, void *data) {
  (void)size;
  /* the first object reported is the main executable */
  for (int i = 0; i < info->dlpi_phnum; i++) {
    if (info->dlpi_phdr[i].p_type == PT_TLS) {
      size_t memsz = info->dlpi_phdr[i].p_memsz;
      size_t align = info->dlpi_phdr[i].p_align ? info->dlpi_phdr[i].p_align : 1;
      size_t rounded = (memsz + align - 1) & ~(align - 1);
      uint8_t *tp = (uint8_t *)__builtin_thread_pointer();
#if defined(__x86_64__) || defined(__i386__)
      /* TLS variant II: the executable's block ends at the thread pointer */
      agS->tlsLo = tp - rounded;
      agS->tlsHi = tp;
#else
      /* TLS variant I (aarch64): block starts after the 16-byte TCB */
      agS->tlsLo = tp + 16;
      agS->tlsHi = tp + 16 + rounded;
#endif
      (void)data;
      return 1;
    }
  }
  return 1;
}

static void agPrintStats(void);

static void agInit(void) {
  AgState *s = (AgState *)agMap(sizeof(AgState));
  memset(s, 0, sizeof(*s));
  agS = s;
  s->base = (uint8_t *)agMap(AG_RESERVE);
  s->pages = (AgPage *)agMap(AG_MAX_PAGES * sizeof(AgPage));
  s->top = 1;
  s->threshold = 8u << 20;
  s->hashCap = 1024;
  s->typeHash = (uint32_t *)calloc(s->hashCap, sizeof(uint32_t));
  const char *e;
  if ((e = getenv("AOWLGC_STRESS")) && *e) { s->stress = atol(e); if (s->stress <= 0) s->stress = 1; s->poison = 1; }
  if ((e = getenv("AOWLGC_VERIFY")) && *e && *e != '0') s->verify = 1;
  if ((e = getenv("AOWLGC_POISON")) && *e && *e != '0') s->poison = 1;
  if ((e = getenv("AOWLGC_STATS")) && *e && *e != '0') { s->stats = 1; atexit(agPrintStats); }
  pthread_attr_t attr;
  if (pthread_getattr_np(pthread_self(), &attr) == 0) {
    void *addr; size_t sz;
    pthread_attr_getstack(&attr, &addr, &sz);
    s->stackBase = (uint8_t *)addr + sz;
    pthread_attr_destroy(&attr);
  } else {
    agDie("cannot determine the stack base");
  }
  dl_iterate_phdr(agTlsCb, NULL);
  s->inited = 1;
}

static inline AgState *agState(void) {
  if (__builtin_expect(agS == NULL, 0)) agInit();
  return agS;
}

/* ---- type ids ---------------------------------------------------------- */

static inline uint32_t agHashFns(void *a, void *b) {
  uint64_t h = (uint64_t)(uintptr_t)a * 0x9E3779B97F4A7C15ull ^ ((uint64_t)(uintptr_t)b + 0x632BE59BD9B4E019ull);
  h ^= h >> 29;
  return (uint32_t)h;
}

static void agRehash(AgState *s) {
  uint32_t nc = s->hashCap * 2;
  uint32_t *nh = (uint32_t *)calloc(nc, sizeof(uint32_t));
  for (uint32_t t = 0; t < s->ntypes; t++) {
    uint32_t i = agHashFns((void *)s->types[t].trace, (void *)s->types[t].fin) & (nc - 1);
    while (nh[i]) i = (i + 1) & (nc - 1);
    nh[i] = t + 1;
  }
  free(s->typeHash);
  s->typeHash = nh;
  s->hashCap = nc;
}

static uint16_t agTypeId(AgState *s, void *trace, void *fin) {
  uint32_t i = agHashFns(trace, fin) & (s->hashCap - 1);
  for (;;) {
    uint32_t t = s->typeHash[i];
    if (t == 0) break;
    AgTypeInfo *ti = &s->types[t - 1];
    if ((void *)ti->trace == trace && (void *)ti->fin == fin) return (uint16_t)(t - 1);
    i = (i + 1) & (s->hashCap - 1);
  }
  if (s->ntypes >= 65535) agDie("too many types");
  size_t cap = s->capTypes;
  s->types = (AgTypeInfo *)agGrow(s->types, &cap, sizeof(AgTypeInfo), s->ntypes + 1);
  s->capTypes = (uint32_t)cap;
  uint16_t tid = (uint16_t)s->ntypes++;
  s->types[tid].trace = (AgTraceFn)trace;
  s->types[tid].fin = (AgFinFn)fin;
  s->typeHash[i] = tid + 1u;
  if (s->ntypes * 2 > s->hashCap) agRehash(s);
  return tid;
}

/* ---- pages ------------------------------------------------------------- */

static inline AgPage *agPageOf(AgState *s, size_t idx) { return &s->pages[idx]; }
static inline uint8_t *agPageAddr(AgState *s, size_t idx) { return s->base + (idx << AG_PAGE_SHIFT); }

static size_t agTakePages(AgState *s, size_t n) {
  /* first fit in the free span list */
  for (size_t i = 0; i < s->nFreeSpans; i++) {
    size_t first = s->freeSpans[2 * i], cnt = s->freeSpans[2 * i + 1];
    if (cnt >= n) {
      if (cnt == n) {
        s->nFreeSpans--;
        s->freeSpans[2 * i] = s->freeSpans[2 * s->nFreeSpans];
        s->freeSpans[2 * i + 1] = s->freeSpans[2 * s->nFreeSpans + 1];
      } else {
        s->freeSpans[2 * i] = first + n;
        s->freeSpans[2 * i + 1] = cnt - n;
      }
      return first;
    }
  }
  if (s->top + n > AG_MAX_PAGES) agDie("heap reservation exhausted");
  size_t first = s->top;
  s->top += n;
  return first;
}

static void agReleasePages(AgState *s, size_t first, size_t n) {
  for (size_t i = 0; i < n; i++) memset(agPageOf(s, first + i), 0, sizeof(AgPage));
  madvise(agPageAddr(s, first), n * AG_PAGE_SIZE, MADV_DONTNEED); /* zero on reuse */
  size_t cap = s->capFreeSpans;
  s->freeSpans = (size_t *)agGrow(s->freeSpans, &cap, 2 * sizeof(size_t), s->nFreeSpans + 1);
  s->capFreeSpans = cap;
  s->freeSpans[2 * s->nFreeSpans] = first;
  s->freeSpans[2 * s->nFreeSpans + 1] = n;
  s->nFreeSpans++;
}

static inline int agSizeClass(size_t total) {
  int lo = 0, hi = (int)AG_NSC - 1;
  while (lo < hi) {
    int mid = (lo + hi) / 2;
    if (agSizeClasses[mid] >= total) hi = mid; else lo = mid + 1;
  }
  return lo;
}

/* Interior/conservative lookup: the header of the live object containing
   address `a`, or NULL. */
static inline AgHeader *agLookup(AgState *s, uintptr_t a) {
  uintptr_t b = (uintptr_t)s->base;
  if (a < b + AG_PAGE_SIZE || a >= b + (s->top << AG_PAGE_SHIFT)) return NULL;
  size_t idx = (a - b) >> AG_PAGE_SHIFT;
  AgPage *pg = agPageOf(s, idx);
  switch (pg->kind) {
  case P_SMALL: {
    uintptr_t start = (uintptr_t)agPageAddr(s, idx);
    uint32_t slot = (uint32_t)((a - start) / pg->slotSize);
    if (slot >= pg->bump) return NULL;
    AgHeader *h = (AgHeader *)(start + (uintptr_t)slot * pg->slotSize);
    return (h->flags & F_ALLOC) ? h : NULL;
  }
  case P_CONT:
    idx = pg->head;
    pg = agPageOf(s, idx);
    /* fallthrough */
  case P_LARGE: {
    AgHeader *h = (AgHeader *)agPageAddr(s, idx);
    return (h->flags & F_ALLOC) ? h : NULL;
  }
  default:
    return NULL;
  }
}

static inline size_t agSlotBytes(AgState *s, AgHeader *h) {
  size_t idx = ((uintptr_t)h - (uintptr_t)s->base) >> AG_PAGE_SHIFT;
  AgPage *pg = agPageOf(s, idx);
  if (pg->kind == P_SMALL) return pg->slotSize;
  return pg->npages * AG_PAGE_SIZE;
}

/* ---- collection -------------------------------------------------------- */

static inline void agPush(AgState *s, AgHeader *h) {
  if (s->nwork == s->capWork) {
    size_t cap = s->capWork;
    s->work = (AgHeader **)agGrow(s->work, &cap, sizeof(AgHeader *), s->nwork + 1);
    s->capWork = cap;
  }
  s->work[s->nwork++] = h;
}

static inline void agMarkWord(AgState *s, uintptr_t w) {
  AgHeader *h = agLookup(s, w);
  if (h && !(h->flags & F_MARK)) {
    h->flags |= F_MARK;
    agPush(s, h);
  }
}

static void agScanRange(AgState *s, const void *lo, const void *hi) {
  uintptr_t a = ((uintptr_t)lo + sizeof(void *) - 1) & ~(uintptr_t)(sizeof(void *) - 1);
  for (; a + sizeof(void *) <= (uintptr_t)hi; a += sizeof(void *))
    agMarkWord(s, *(const uintptr_t *)a);
}

static void agDrain(AgState *s) {
  while (s->nwork > 0) {
    AgHeader *h = s->work[--s->nwork];
    uint8_t *payload = (uint8_t *)h + AG_HDR;
    if (h->flags & F_CONSERVATIVE) {
      agScanRange(s, payload, (uint8_t *)h + agSlotBytes(s, h));
    } else {
      AgTraceFn t = s->types[h->tid].trace;
      if (t) t(payload, (void *)s);
    }
  }
}

void aowlgcMark(void *env, void *p) {
  AgState *s = agS;
  if (p == NULL || s == NULL) return;
  if (s->verifying) {
    AgHeader *h = agLookup(s, (uintptr_t)p);
    s->verifiedEdges++;
    if (h == NULL || !(h->flags & F_MARK) || (uint8_t *)h + AG_HDR != (uint8_t *)p) {
      uintptr_t b = (uintptr_t)s->base;
      if ((uintptr_t)p >= b && (uintptr_t)p < b + AG_RESERVE) {
        fprintf(stderr, "aowlgc verify: live object has an edge to %p which is %s\n", p,
                h == NULL ? "not a live heap object" :
                !(h->flags & F_MARK) ? "unmarked" : "an interior pointer");
        abort();
      }
    }
    return;
  }
  (void)env;
  agMarkWord(s, (uintptr_t)p);
}

static void agForEachObject(AgState *s, void (*fn)(AgState *, AgHeader *)) {
  for (size_t idx = 1; idx < s->top; idx++) {
    AgPage *pg = agPageOf(s, idx);
    if (pg->kind == P_SMALL) {
      uint8_t *start = agPageAddr(s, idx);
      for (uint32_t i = 0; i < pg->bump; i++) {
        AgHeader *h = (AgHeader *)(start + (size_t)i * pg->slotSize);
        if (h->flags & F_ALLOC) fn(s, h);
      }
    } else if (pg->kind == P_LARGE) {
      AgHeader *h = (AgHeader *)agPageAddr(s, idx);
      if (h->flags & F_ALLOC) fn(s, h);
    }
  }
}

static void agRootPinned(AgState *s, AgHeader *h) {
  if (((h->flags & F_PINNED) || h->pins) && !(h->flags & F_MARK)) {
    h->flags |= F_MARK;
    agPush(s, h);
  }
}

static void agVerifyOne(AgState *s, AgHeader *h) {
  if ((h->flags & F_MARK) && !(h->flags & F_CONSERVATIVE)) {
    AgTraceFn t = s->types[h->tid].trace;
    if (t) t((uint8_t *)h + AG_HDR, (void *)s);
  }
}

static void agFinalizeOne(AgState *s, AgHeader *h) {
  if (!(h->flags & F_MARK) && !(h->flags & F_CONSERVATIVE)) {
    AgFinFn f = s->types[h->tid].fin;
    if (f) { s->finalized++; f((uint8_t *)h + AG_HDR); }
  }
}

static void agFreeSlot(AgState *s, AgHeader *h);

static void agSweepOne(AgState *s, AgHeader *h) {
  if (h->flags & F_MARK) {
    h->flags &= (uint8_t)~F_MARK;
    s->liveBytes += agSlotBytes(s, h);
  } else {
    agFreeSlot(s, h);
  }
}

static void __attribute__((noinline)) agMarkRoots(AgState *s) {
  jmp_buf regs;
  __builtin_unwind_init();
  setjmp(regs);
  agScanRange(s, &regs, (uint8_t *)&regs + sizeof(regs));
  volatile uintptr_t marker = 0;
  agScanRange(s, (const void *)&marker, s->stackBase);
  agScanRange(s, __data_start, _end);
  if (s->tlsLo) agScanRange(s, s->tlsLo, s->tlsHi);
  agForEachObject(s, agRootPinned);
}

void aowlgcCollect(void) {
  AgState *s = agState();
  if (s->inGc) return;
  s->inGc = 1;
  s->collections++;
  agMarkRoots(s);
  agDrain(s);
  if (s->verify) {
    s->verifying = 1;
    agForEachObject(s, agVerifyOne);
    s->verifying = 0;
  }
  /* phase 1: finalizers (they may read dead objects; nothing is freed yet).
     Objects they allocate are allocated black and survive this cycle. */
  s->inFinalizers = 1;
  agForEachObject(s, agFinalizeOne);
  s->inFinalizers = 0;
  /* phase 2: free the dead, unmark the living */
  s->liveBytes = 0;
  agForEachObject(s, agSweepOne);
  s->bytesSinceGc = 0;
  s->threshold = s->liveBytes > (8u << 20) ? s->liveBytes : (8u << 20);
  s->inGc = 0;
}

/* ---- allocation -------------------------------------------------------- */

static AgHeader *agAllocSlot(AgState *s, size_t total) {
  AgHeader *h;
  if (total <= AG_MAX_SMALL) {
    int sc = agSizeClass(total);
    AgPage *pg = s->avail[sc];
    while (pg && pg->freeList == NULL && pg->bump == pg->nslots) {
      pg->inAvail = 0;
      pg = s->avail[sc] = pg->nextAvail;
    }
    if (pg == NULL) {
      size_t idx = agTakePages(s, 1);
      pg = agPageOf(s, idx);
      memset(pg, 0, sizeof(*pg));
      pg->kind = P_SMALL;
      pg->sc = (uint8_t)sc;
      pg->slotSize = agSizeClasses[sc];
      pg->nslots = (uint32_t)(AG_PAGE_SIZE / pg->slotSize);
      pg->nextAvail = s->avail[sc];
      pg->inAvail = 1;
      s->avail[sc] = pg;
    }
    size_t idx = (size_t)(pg - s->pages);
    if (pg->freeList) {
      h = (AgHeader *)pg->freeList;
      pg->freeList = *(void **)((uint8_t *)h + AG_HDR);
      memset(h, 0, pg->slotSize);
    } else {
      h = (AgHeader *)(agPageAddr(s, idx) + (size_t)pg->bump * pg->slotSize);
      pg->bump++;
      /* fresh or MADV_DONTNEED'd memory is zero */
    }
    pg->used++;
    h->sc = (uint8_t)sc;
    s->bytesSinceGc += pg->slotSize;
  } else {
    size_t n = (total + AG_PAGE_SIZE - 1) >> AG_PAGE_SHIFT;
    size_t first = agTakePages(s, n);
    AgPage *pg = agPageOf(s, first);
    memset(pg, 0, sizeof(*pg));
    pg->kind = P_LARGE;
    pg->npages = n;
    for (size_t i = 1; i < n; i++) {
      AgPage *c = agPageOf(s, first + i);
      memset(c, 0, sizeof(*c));
      c->kind = P_CONT;
      c->head = (uint32_t)first;
    }
    h = (AgHeader *)agPageAddr(s, first);
    s->bytesSinceGc += n * AG_PAGE_SIZE;
  }
  h->flags = F_ALLOC | (s->inGc ? F_MARK : 0);
  s->allocs++;
  return h;
}

static void agFreeSlot(AgState *s, AgHeader *h) {
  size_t idx = ((uintptr_t)h - (uintptr_t)s->base) >> AG_PAGE_SHIFT;
  AgPage *pg = agPageOf(s, idx);
  s->frees++;
  if (pg->kind == P_SMALL) {
    if (s->poison) memset(h, 0xDB, pg->slotSize);
    h->flags = 0;
    *(void **)((uint8_t *)h + AG_HDR) = pg->freeList;
    pg->freeList = h;
    pg->used--;
    if (!pg->inAvail) {
      pg->inAvail = 1;
      pg->nextAvail = s->avail[pg->sc];
      s->avail[pg->sc] = pg;
    }
  } else {
    h->flags = 0;
    agReleasePages(s, idx, pg->npages);
  }
}

static inline void agMaybeCollect(AgState *s) {
  if (s->inGc) return;
  if (s->stress) {
    if (++s->stressCount >= s->stress) { s->stressCount = 0; aowlgcCollect(); }
  } else if (s->bytesSinceGc >= s->threshold) {
    aowlgcCollect();
  }
}

void *aowlgcNew(intptr_t size, void *trace, void *fin) {
  AgState *s = agState();
  agMaybeCollect(s);
  uint16_t tid = agTypeId(s, trace, fin);
  AgHeader *h = agAllocSlot(s, (size_t)size + AG_HDR);
  h->tid = tid;
  return (uint8_t *)h + AG_HDR;
}

void *aowlgcNewTraced(intptr_t size, AgTraceFn trace) {
  return aowlgcNew(size, (void *)trace, NULL);
}

void *aowlgcAllocPinned(intptr_t size) {
  AgState *s = agState();
  agMaybeCollect(s);
  AgHeader *h = agAllocSlot(s, (size_t)size + AG_HDR);
  h->flags |= F_PINNED | F_CONSERVATIVE;
  return (uint8_t *)h + AG_HDR;
}

static inline AgHeader *agExact(AgState *s, void *p) {
  AgHeader *h = agLookup(s, (uintptr_t)p);
  if (h == NULL || (uint8_t *)h + AG_HDR != (uint8_t *)p) return NULL;
  return h;
}

void aowlgcFree(void *p) {
  AgState *s = agS;
  if (p == NULL || s == NULL) return;
  /* During a collection the dead are freed by the sweep; an explicit free
     from a finalizer is redundant (and could double-free). */
  if (s->inGc) return;
  AgHeader *h = agExact(s, p);
  if (h) agFreeSlot(s, h);
}

void aowlgcFreePinned(void *p) { aowlgcFree(p); }

intptr_t aowlgcUsableSize(void *p) {
  AgState *s = agS;
  if (p == NULL || s == NULL) return 0;
  AgHeader *h = agExact(s, p);
  if (h == NULL) return 0;
  return (intptr_t)(agSlotBytes(s, h) - AG_HDR);
}

void aowlgcPin(void *p) {
  AgState *s = agS;
  if (p == NULL || s == NULL) return;
  AgHeader *h = agExact(s, p);
  if (h) h->pins++;
}

void aowlgcUnpin(void *p) {
  AgState *s = agS;
  if (p == NULL || s == NULL) return;
  AgHeader *h = agExact(s, p);
  if (h && h->pins) h->pins--;
}

int aowlgcIsLive(void *p) {
  AgState *s = agS;
  if (p == NULL || s == NULL) return 0;
  return agExact(s, p) != NULL;
}

intptr_t aowlgcStat(intptr_t which) {
  AgState *s = agState();
  switch (which) {
  case 0: return (intptr_t)s->collections;
  case 1: return (intptr_t)s->allocs;
  case 2: return (intptr_t)s->frees;
  case 3: return (intptr_t)s->finalized;
  case 4: return (intptr_t)(s->allocs - s->frees); /* live objects */
  case 5: return (intptr_t)s->liveBytes;
  case 6: return (intptr_t)s->ntypes;
  case 7: return (intptr_t)s->verifiedEdges;
  default: return -1;
  }
}

static void agPrintStats(void) {
  AgState *s = agS;
  if (!s) return;
  fprintf(stderr, "aowlgc: collections=%zu allocs=%zu frees=%zu finalized=%zu live=%zu types=%u edges-verified=%zu\n",
          s->collections, s->allocs, s->frees, s->finalized, s->allocs - s->frees, s->ntypes, s->verifiedEdges);
}
