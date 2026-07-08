#       Nimony
# (c) Copyright 2024 Andreas Rumpf
#
# See the file "license.txt", included in this
# distribution, for details about the copyright.

## Nimony semantic checker.

import std / [parseopt, sets, strutils, os, assertions, syncio, json]

import ".." / gear2 / modnames
import ".." / lib / [argsfinder, symparser, nifcursors, nifstreams, nifreader,
                     nifbuilder, nifindexes, tooldirs, vfs]
import semmain, sem, nifconfig, semos, semdata, indexgen, programs,
       derefs, deps, idetools, cli, langmodes

const
  Version = slurp("../../doc/version.md")
  Usage = "Nimsem Semantic Checker. Version " & Version & """

  (c) 2024-2025 Andreas Rumpf
Usage:
  nimsem [options] [command]
Command:
  m input.nif                 compile a single Nim module to hexer (output and index files derived from input name)
  x file.nif                  generate the .idx.nif file from a .nif file
  e file.nif [dep1.nif ...]   execute the given .nif file
  idetools file1.nif [file2.nif ...]  list usages and definitions
  serve                       persistent warm semcheck worker; JSONL protocol
                              on stdin/stdout (see docs/daemon-protocol.md)

Options:
  -d, --define:SYMBOL       define a symbol for conditional compilation
  -p, --path:PATH           add PATH to the search path
  --compat                  turn on compatibility mode
  --isSystem                passed module is a `system.nim` module
  --isMain                  passed module is the main module of a project
  --noSystem                do not auto-import `system.nim`
  --bits:N                  `int` has N bits; possible values: 64, 32, 16
  --cpu:SYMBOL              set the target processor (cross-compilation)
  --os:SYMBOL               set the target operating system (cross-compilation)
  --app:console|gui|lib|staticlib
                            set the application type (default: console)
  --base:PATH               set the base directory for the configuration system
  --nimcache:PATH           set the path used for generated files
  --flags:FLAGS             undocumented flags
  --novalidate              skip running the plugin validator on plugin sources
  --verbose                 dump NJVL IR (and other diagnostics) on contract
                            analysis failures
  --version                 show the version
  --help                    show this help
"""

proc writeHelp() = quit(Usage, QuitSuccess)
proc writeVersion() = quit(Version & "\n", QuitSuccess)

type
  Command = enum
    None, SingleModule, GenerateIdx, Execute, Idetools, Serve

proc processModules(infiles: seq[string]; config: sink NifConfig;
                    moduleFlags: set[ModuleFlag]; commandLineArgs: string) =
  for infile in infiles:
    # `hasOverlay`: a `nimsem serve` client may have submitted an in-memory
    # dirty buffer for a file that need not exist on disk.
    if not (semos.fileExists(infile) or hasOverlay(infile)):
      quit "cannot find " & infile
  var outfiles: seq[string] = @[]
  for infile in infiles:
    # Mirror the doc-mode prefix: `.pc.nif` → `.sc.nif`, plain `.p.nif` → `.s.nif`.
    # Keeps the doc and code-gen caches separate so they don't trample each other.
    let outExt = if infile.endsWith(".pc.nif"): ".sc.nif" else: ".s.nif"
    outfiles.add infile.changeModuleExt(outExt)
  semcheck(infiles, outfiles, ensureMove config, moduleFlags, commandLineArgs, false)

proc executeNif(files: seq[string]; config: sink NifConfig) =
  # file 0 is special as it is the main file. We need to run injectDerefs on it first.
  # The other modules are simply dependencies we need to compile&link too.
  if files.len == 0:
    return

  # little hack: prepare our writenif dependency.
  # Forward `--cc` so the nested nimony's idea of `defined(gcc)` /
  # `defined(clang)` matches the outer nimsem's. Otherwise the nested
  # build sees system.s.nif (already produced by the outer pass under
  # the outer's `--cc` profile) as stale for its own profile and tries
  # to rewrite it — and on Windows that write open fails because the
  # outer nimsem still has the file mmap'd.
  exec quoteShell(findTool("nimony")) & " --nimcache:" & quoteShell(config.nifcachePath) &
    " c " & quoteShell(stdlibFile("std/writenif.nim"))

  var dependencyFiles: seq[string] = @[]
  for i in 1..files.high: dependencyFiles.add files[i]

  buildGraphForEval(
    config = config,
    mainNifFile = files[0],
    dependencyNifFiles = dependencyFiles,
    flags = {},
    moduleFlags = {}
  )

const DaemonProtocolVersion = 0

proc semOutputsFor(infiles: seq[string]): seq[string] =
  ## The files `processModules` writes for `infiles`, so the client learns which
  ## artifacts changed. Mirrors `processModules`/`writeOutput`.
  result = @[]
  for infile in infiles:
    let outExt = if infile.endsWith(".pc.nif"): ".sc.nif" else: ".s.nif"
    let base = infile.changeModuleExt(outExt)
    result.add base
    result.add infile.changeModuleExt(if outExt == ".sc.nif": ".sc.idx.nif" else: ".s.idx.nif")

proc runSemcheckJob(args: seq[string]): seq[string] =
  ## Run ONE single-module semcheck job for argv `args`, using exactly the same
  ## option handling and config setup as the one-shot `nimsem m` path (see the
  ## SingleModule branch below) so the produced `.s.nif`/`.s.idx.nif` are
  ## byte-identical. Returns the output files written.
  var infiles: seq[string] = @[]
  var moduleFlags: set[ModuleFlag] = {}
  var config = initNifConfig("")
  var commandLineArgs = ""
  for a in args:
    if a.len >= 2 and a[0] == '-' and a[1] == '-':
      # option of the form --key or --key:val
      let colon = a.find(':')
      let key = if colon >= 0: a[2 ..< colon] else: a[2 .. ^1]
      let val = if colon >= 0: a[colon+1 .. ^1] else: ""
      var forwardArg = true
      var forwardArgLengc = false
      if parseCommonOption(key, val, config, moduleFlags, forwardArg, forwardArgLengc,
                          helpMsg = Usage, versionMsg = Version & "\n"):
        discard "handled by common CLI parser"
      else:
        case normalize(key)
        of "forcebuild", "f", "ff": discard
        else: discard
      if forwardArg:
        commandLineArgs.add " --" & key
        if val.len > 0:
          commandLineArgs.add ":" & val
    else:
      infiles.add a
  semos.setupPaths(config)
  if config.linker.len == 0 and config.cc.len > 0:
    config.linker = config.cc
  if infiles.len < 1:
    raise newException(ValueError, "semcheck: request needs at least 1 input file")
  result = semOutputsFor(infiles)
  processModules(infiles, ensureMove config, moduleFlags, commandLineArgs)

proc jsErr(id: JsonNode; verb, msg: string): JsonNode =
  result = %*{"v": DaemonProtocolVersion, "id": id, "verb": verb,
              "ok": false, "error": msg}

proc handleRequest(req: JsonNode): JsonNode =
  ## Dispatch one v0 envelope. See docs/daemon-protocol.md.
  let id = if req.hasKey("id"): req["id"] else: newJNull()
  let verb = if req.hasKey("verb"): req["verb"].getStr() else: ""
  # Inline overlays (dirty buffers) are installed before any verb runs and
  # persist until cleared/replaced — matching editor "unsaved buffer" semantics.
  if req.hasKey("overlays"):
    for ov in req["overlays"]:
      setOverlay(ov["path"].getStr(), ov["content"].getStr())
  case verb
  of "semcheck", "recheck":
    # INVALIDATION: evict stale / wrong-phase cached modules before serving.
    prepareForNextRequest()
    var args: seq[string] = @[]
    if req.hasKey("args"):
      for a in req["args"]: args.add a.getStr()
    try:
      let outputs = runSemcheckJob(args)
      var outArr = newJArray()
      for o in outputs: outArr.add %o
      result = %*{"v": DaemonProtocolVersion, "id": id, "verb": verb,
                  "ok": true, "outputs": outArr, "diagnostics": newJArray()}
    except CatchableError as e:
      result = jsErr(id, verb, e.msg)
  of "setOverlay":
    setOverlay(req["path"].getStr(), req["content"].getStr())
    result = %*{"v": DaemonProtocolVersion, "id": id, "verb": verb, "ok": true}
  of "clearOverlay":
    if req.hasKey("path"): delOverlay(req["path"].getStr())
    else: clearOverlays()
    result = %*{"v": DaemonProtocolVersion, "id": id, "verb": verb, "ok": true}
  of "shutdown", "quit", "bye":
    result = %*{"v": DaemonProtocolVersion, "id": id, "verb": "shutdown", "ok": true}
  of "defs", "typeDefinition", "callHierarchy", "symbols":
    # RESERVED (schema fixed in v0; handler to be implemented). Query responses
    # are keyed by symbol id under a "symbols" object. These verbs REQUIRE the
    # warm whole-program symbol graph for exact cross-module overload resolution
    # (go-to-def, go-to-type-def, call hierarchy). See docs/daemon-protocol.md.
    result = jsErr(id, verb, "unimplemented in v0 prototype")
  else:
    result = jsErr(id, verb, "unknown verb: " & verb)

proc serveLoop() =
  ## Persistent-worker main loop. Reads one JSON request per line (JSONL) from
  ## stdin, keeps `pool`/`prog.mods` interned across requests, and writes one
  ## JSON reply per line to stdout. Diagnostics stay on stderr. `semcheck` still
  ## `quit`s on a hard sem error (prototype). See docs/daemon-protocol.md.
  stderr.writeLine "[nimsem serve] ready v" & $DaemonProtocolVersion
  stderr.flushFile()
  var line: string = ""
  while stdin.readLine(line):
    let raw = line.strip()
    if raw.len == 0: continue
    var req: JsonNode
    try:
      req = parseJson(raw)
    except CatchableError as e:
      stdout.writeLine $(%*{"v": DaemonProtocolVersion, "ok": false,
                            "error": "bad JSON: " & e.msg})
      stdout.flushFile()
      continue
    let reply = handleRequest(req)
    stdout.writeLine $reply
    stdout.flushFile()
    if reply["verb"].getStr() == "shutdown" and reply["ok"].getBool(): break

proc handleCmdLine() =
  var args: seq[string] = @[]
  var cmd = Command.None
  var forceRebuild = false
  var moduleFlags: set[ModuleFlag] = {}
  var config = initNifConfig("")
  var commandLineArgs = ""
  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      if cmd == None:
        case key.normalize:
        of "m":
          cmd = SingleModule
        of "x":
          cmd = GenerateIdx
        of "e":
          cmd = Execute
        of "idetools":
          cmd = Idetools
        of "serve":
          cmd = Serve
        else:
          quit "command expected"
      else:
        args.add key

    of cmdLongOption, cmdShortOption:
      var forwardArg = true
      var forwardArgLengc = false  # nimsem doesn't use this, but needed for parseCommonOption
      if parseCommonOption(key, val, config, moduleFlags, forwardArg, forwardArgLengc,
                          helpMsg = Usage, versionMsg = Version & "\n"):
        discard "handled by common CLI parser"
      else:
        case normalize(key)
        of "forcebuild", "f", "ff": forceRebuild = true
        else: writeHelp()
      if forwardArg:
        commandLineArgs.add " --" & key
        if val.len > 0:
          # Raw value: see the matching comment in nimony.nim. These args end
          # up as StringLits in the `.build.nif`, which nifmake quotes once.
          commandLineArgs.add ":" & val

    of cmdEnd: assert false, "cannot happen"
  semos.setupPaths(config)
  if config.linker.len == 0 and config.cc.len > 0:
    config.linker = config.cc

  case cmd
  of None:
    quit "command missing"
  of SingleModule:
    if args.len < 1:
      quit "want at least 1 command line argument"
    processModules(args, ensureMove config, moduleFlags, commandLineArgs)
  of GenerateIdx:
    if args.len != 1:
      quit "want exactly 1 command line argument"
    indexFromNif(args[0])
  of Execute:
    if args.len == 0:
      quit "want more than 0 command line argument"
    executeNif args, ensureMove config
  of Idetools:
    if args.len == 0:
      quit "want more than 0 command line argument"
    case config.toTrack.mode
    of TrackUsages, TrackDef:
      usages(args, config)
    of TrackNone:
      quit "no --track information provided"
  of Serve:
    serveLoop()

when isMainModule:
  handleCmdLine()
  when defined(internStats):
    stderr.writeLine "[internStats] interfaceLoads=", interfaceLoads,
      " totalModuleLoads=", totalModuleLoads
  when defined(prepMutStats):
    stderr.writeLine "[prepMutStats] fast=", cowFastCount,
      " slow=", cowSlowCount,
      " slowBytes=", cowSlowBytes,
      " cmdline=", commandLineParams().join(" ")
  dumpVfsProfile("nimsem")
