/* CreateThread's real prototype (from <Windows.h>) types its last parameter
   as DWORD*, i.e. unsigned long* on MinGW/UCRT - Nimony's `culong` codegens
   to a plain `unsigned int` (NU32) instead: same width, different nominal
   type, and newer GCC treats incompatible-pointer-types as an error by
   default (-w does not turn that back into a warning). A type alias
   importc'd to the real DWORD name does not survive into codegen at a
   parameter position.
   This file is compiled and linked as its own translation unit (via
   `{.compile.}` in rawthreads.nim), so its own use of <Windows.h>'s exact
   types never has to reconcile with any Nim-side declaration: C linking
   only matches symbol name and calling convention across files, not exact
   type spelling, so Nimony's own consistent (if differently-named)
   auto-generated forward declaration in every calling .c file links fine
   against this real definition. `startAddr`/`arg`/`stackSize` need no such
   shim - Nimony's WinThreadProc/pointer/culong already pass cleanly through
   a plain importc'd FFI call; only the DWORD* out-parameter needed hiding,
   and this file owns and discards it internally. */
#include <Windows.h>

HANDLE nimonyWinCreateThread(LPTHREAD_START_ROUTINE startAddr, void* arg, unsigned long stackSize) {
  DWORD dummyId = 0;
  return CreateThread(NULL, (SIZE_T)stackSize, startAddr, arg, 0, &dummyId);
}
