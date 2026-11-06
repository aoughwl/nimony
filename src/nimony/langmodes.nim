#       Nimony
# (c) Copyright 2025 Andreas Rumpf
#
# See the file "license.txt", included in this
# distribution, for details about the copyright.

## Language modes ("check X:on|off") for Nimony.

type
  CheckMode* = enum
    BoundCheck
    RangeCheck
    AowlGc     ## not a check: the aowlgc memory mode (refs in the tracing heap)

  ModuleFlag* = enum
    IsSystem, IsMain, SkipSystem

const
  DefaultSettings* = {BoundCheck, RangeCheck}

const
  shortcuts: array[CheckMode, char] = [
    BoundCheck: 'b',
    RangeCheck: 'r',
    AowlGc: 'g'
  ]

proc genFlags*(s: set[CheckMode]): string =
  result = ""
  for e in s:
    result.add shortcuts[e]

proc parseFlags*(s: string): set[CheckMode] =
  result = {}
  var i = 0
  while i < s.len:
    let c = s[i]
    for m in low(CheckMode) .. high(CheckMode):
      if c == shortcuts[m]:
        result.incl m
        break
    inc i
