import
  std/[deques, macrocache, strutils, times, os],
  stew/[ptrops, strings],
  stew/shims/macros,
  ./[dynamic_scope_types, options, topics_registry]

when defined(js):
  type OutStr = cstring
else:
  type OutStr = string

export LogLevel

type
  FileOutput* = object
    outFile*: File
    outPath: cstring
    mode: FileMode
    colors*: bool

  StdOutOutput* = object
    colors*: bool

  StdErrOutput* = object
    colors*: bool

  SysLogOutput* = object
    currentRecordLevel: LogLevel

  LogOutputStr* = OutStr

  DynamicOutput* = object
    currentRecordLevel: LogLevel
    colors*: bool
    writer*: proc(logLevel: LogLevel, logRecord: OutStr) {.gcsafe, raises: [].}

  PassThroughOutput*[Outputs: tuple] = object
    outputs: Outputs

  AnyOutput =
    FileOutput | StdOutOutput | StdErrOutput | SysLogOutput | PassThroughOutput |
    StreamOutputRef

  StreamOutputRef*[Stream; outputId: static[int]] = object
    ## Stream outputs from the global configuration are stored in a global
    ## tuple with each output indexed by outputId - to access it, `deref` of
    ## `StreamOutputRef` is used.

  StreamCodeNodes = object
    streamName: NimNode
    recordType: NimNode
    outputsTuple: NimNode

when defined(posix):
  {.pragma: syslog_h, importc, header: "<syslog.h>".}

  # proc openlog(ident: cstring, option, facility: int) {.syslog_h.}
  proc syslog(priority: int, format: cstring, msg: cstring) {.syslog_h.}
  # proc closelog() {.syslog_h.}

  # var LOG_EMERG {.syslog_h.}: int
  # var LOG_ALERT {.syslog_h.}: int
  var LOG_CRIT {.syslog_h.}: int
  var LOG_ERR {.syslog_h.}: int
  var LOG_WARNING {.syslog_h.}: int
  var LOG_NOTICE {.syslog_h.}: int
  var LOG_INFO {.syslog_h.}: int
  var LOG_DEBUG {.syslog_h.}: int

  var LOG_PID {.syslog_h.}: int

# XXX: `bindSym` is currently broken and doesn't return proper type symbols
# (the resulting nodes should have a `tyTypeDesc` type, but they don't)
# Until this is fixed, use regular ident nodes to work-around the problem.
template bnd(s): NimNode =
  # bindSym(s)
  newIdentNode(s)

template deref(so: StreamOutputRef): auto =
  (outputs(so.Stream))[so.outputId]

when defined(windows):
  # MS recommends that ANSI colors are used for the terminal:
  # https://learn.microsoft.com/en-us/windows/console/classic-vs-vt
  #
  # ANSI colors are available from Windows 10+ and need to be explicitly enabled.
  # Instead of trying to detect versions, we simply try to enable it and revert
  # back to no colors if it doesn't work:
  # https://learn.microsoft.com/en-us/windows/console/console-virtual-terminal-sequences#example-of-enabling-virtual-terminal-processing
  #
  # std/terminal is broken at the time of writing, ie the version check uses a
  # deprecated version check api that may or may not work depending on how the
  # application is built:
  # https://msdn.microsoft.com/en-us/library/windows/desktop/ms724451(v=vs.85).aspx
  import winlean
  const ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004

  proc getConsoleMode(hConsoleHandle: Handle, dwMode: ptr DWORD): WINBOOL{.
      stdcall, dynlib: "kernel32", importc: "GetConsoleMode".}

  proc setConsoleMode(hConsoleHandle: Handle, dwMode: DWORD): WINBOOL{.
      stdcall, dynlib: "kernel32", importc: "SetConsoleMode".}

when defined(js):
  proc hasNoColor(): bool = true
  proc enableColors(f: File): bool = false
else:
  import std/terminal

  proc hasNoColor(): bool =
    when declared(getEnv):
      # https://no-color.org/
      getEnv("NO_COLOR").len > 0
    else:
      false

  proc enableColors(f: File): bool =
    if not isatty(f):
      return false

    if hasNoColor():
      return false

    when defined(windows):
      let handle = getStdHandle(
        if f == stderr: STD_ERROR_HANDLE
        else: STD_OUTPUT_HANDLE)

      var mode: DWORD = 0
      if getConsoleMode(handle, addr(mode)) != 0:
        mode = mode or ENABLE_VIRTUAL_TERMINAL_PROCESSING
        setConsoleMode(handle, mode) != 0
      else:
        false
    else:
      true

template ignoreIOErrors(body: untyped) =
  try: body
  except IOError: discard

proc logLoggingFailure*(msg: cstring, ex: ref Exception) =
  when not defined(js):
    ignoreIOErrors:
      stderr.write("[Chronicles] Log message not delivered: ")
      stderr.write(msg)
      if ex != nil: stderr.writeLine(ex.msg)
      stderr.flushFile()

proc undeliveredMsg(reason: string, logMsg: openArray[char], ex: ref Exception) =
  var msg = newStringOfCap(reason.len + 2 + logMsg.len)
  msg.add reason
  msg.add ": "
  msg.add logMsg

  logLoggingFailure(cstring(msg), ex)

proc undeliveredMsg(reason: string, logMsg: openArray[byte], ex: ref Exception) =
  when not defined(js):
    let p = cast[ptr char](logMsg.baseAddr)
    undeliveredMsg(reason, makeOpenArray(p, logMsg.len), ex)

proc defaultDynamicWriter(logLevel: LogLevel, logRecord: OutStr) =
  undeliveredMsg "`dynamic` log output writer not configured", logRecord, nil

when not defined(js):
  template toCString(v: string): cstring =
    let mem = createShared(byte, v.len + 1)
    if v.len > 0:
      copyMem(mem, addr v[0], v.len)
    cast[cstring](mem)

  proc open*(o: ptr FileOutput, path: string, mode = fmAppend): bool =
    if o.outFile != nil:
      close(o.outFile)
      o.outFile = nil

      if o.outPath != nil:
        deallocShared(o.outPath)
        o.outPath = nil

    createDir path.splitFile.dir
    result = open(o.outFile, path, mode)
    if result:
      o.outPath = toCString(path)
      o.mode = mode

  proc open*(o: ptr FileOutput, file: File): bool =
    if o.outFile != nil:
      close(o.outFile)
      deallocShared(o.outPath)
      o.outPath = nil

    o.outFile = file

  proc open*(o: var FileOutput, path: string, mode = fmAppend): bool {.inline.} =
    open(o.addr, path, mode)

  proc open*(o: var FileOutput, file: File): bool {.inline.} =
    open(o.addr, file)

  proc openOutput(o: var FileOutput) =
    doAssert o.outPath.len > 0 and o.mode != fmRead
    let outPath = $o.outPath
    createDir outPath.splitFile.dir
    o.outFile = open(outPath, o.mode)
    o.colors = enableColors(o.outFile)

  proc createFileOutput(path: string, mode: FileMode): FileOutput =
    result.mode = mode
    result.outPath = toCString(path)

  proc createStdOutOutput(): StdOutOutput =
    StdOutOutput(
      colors: enableColors(stdout)
    )
  proc createStdErrOutput(): StdErrOutput =
    StdErrOutput(
      colors: enableColors(stdout)
    )
  proc createDynamicOutput(): DynamicOutput =
    DynamicOutput(
      colors: not hasNoColor(), # The application can choose to modify this later
      writer: defaultDynamicWriter
    )
else:
  proc createStdOutOutput(): StdOutOutput =
    default(StdOutOutput)
  proc createStdErrOutput(): StdErrOutput =
    default(StdErrOutput)
  proc createDynamicOutput(): DynamicOutput =
    DynamicOutput(
      writer: defaultDynamicWriter
    )

# XXX:
# Uncomenting this leads to an error message that the Outputs tuple
# for the created steam doesn't have a defined destuctor. How come
# destructors are not lifted automatically for tuples?
#
#proc `=destroy`*(o: var FileOutput) =
#  if o.outFile != nil:
#    close(o.outFile)

#
# All file outputs are stored inside an `outputs` tuple created for each
# stream (see createStreamSymbol). The files are opened lazily when the
# first log entries are about to be written and they are closed automatically
# at program exit through their destructors (XXX: not working yet, see above).
#
# If some of the file outputs don't have assigned paths in the compile-time
# configuration, chronicles will automatically choose the log file names using
# the following rules:
#
# 1. The log file is created in the current working directory and its name
#    matches the name of the stream (plus a '.log' extension). The exception
#    for this rule is the default stream, for which the log file will be
#    assigned the name of the application binary.
#
# 2. If more than one unnamed file outputs exist for a given stream,
#    chronicles will add an index such as '.2.log', '.3.log' .. '.N.log'
#    to the final file name.
#

when not defined(js):
  proc selectLogName(stream: string, outputId: int): string =
    result = if stream != defaultChroniclesStreamName: stream
             else: getAppFilename().splitFile.name

    if outputId > 1: result.add("." & $outputId)
    result.add ".log"

proc selectOutputType(s: var StreamCodeNodes, dst: LogDestination): NimNode =
  var outputId = s.outputsTuple.len
  if dst.kind == oFile:
    when defined(js):
      error "File outputs are not supported in the js target"
    else:
      outputId = s.outputsTuple.len

      let mode = if dst.truncate: bindSym"fmWrite"
                 else: bindSym"fmAppend"

      let fileName = if dst.filename.len > 0: newLit(dst.filename)
                     else: newCall(bindSym"selectLogName",
                                   newLit($s.streamName), newLit(outputId))

      s.outputsTuple.add newCall(bindSym"createFileOutput", fileName, mode)
  elif dst.kind == oDynamic:
    s.outputsTuple.add newCall(bindSym"createDynamicOutput")
  elif dst.kind == oStdOut:
    s.outputsTuple.add newCall(bindSym"createStdOutOutput")
  elif dst.kind == oStdErr:
    s.outputsTuple.add newCall(bindSym"createStdErrOutput")

  case dst.kind
  of oSysLog: bnd"SysLogOutput"
  of oStdOut, oStdErr, oFile, oDynamic:
    newTree(nnkBracketExpr,
            bnd"StreamOutputRef", s.streamName, newLit(outputId))

template id(fmt: LogFormatPlugin): string =
  "chronicles_" & toHex(string fmt)

proc selectRecordType(s: var StreamCodeNodes, sink: SinkSpec): NimNode =
  # This proc translates the SinkSpecs loaded in the `options` module
  # to their corresponding LogRecord types.

  result = newTree(nnkBracketExpr,
                   newTree(nnkDotExpr, ident(sink.format.id), ident("LogRecord")))

  # Check if a composite output is needed
  if sink.destinations.len > 1:
    # Here, we build the list of outputs as a tuple
    var outputsTuple = newTree(nnkTupleConstr)
    for dst in sink.destinations:
      outputsTuple.add selectOutputType(s, dst)

    var outputType = bnd"PassThroughOutput"
    result.add newTree(nnkBracketExpr, outputType, outputsTuple)
  else:
    result.add selectOutputType(s, sink.destinations[0])

  # create a FormatSpec for the type
  let
    timestamps = newLit(sink.timestamps)
    colors = newLit(sink.colorScheme)

  result.add quote do:
    FormatSpec(colors: `colors`, timestamps: `timestamps`)

# The `append` and `flushOutput` functions implement the actual writing
# to the log destinations (which we call Outputs).
# The LogRecord types are parametric on their Output and this is how we
# can support arbitrary combinations of log formats and destinations.

template activateOutput*(o: var (StdOutOutput|StdErrOutput), level: LogLevel) =
  discard

template activateOutput*(o: var FileOutput, level: LogLevel) =
  if o.outFile == nil: openOutput(o)

template activateOutput*(o: var StreamOutputRef, level: LogLevel) =
  mixin activateOutput
  bind deref
  activateOutput(deref(o), level)

template activateOutput*(o: var (SysLogOutput|DynamicOutput), level: LogLevel) =
  o.currentRecordLevel = level

template activateOutput*(o: var PassThroughOutput, level: LogLevel) =
  mixin activateOutput
  for f in o.outputs.fields:
    activateOutput(f, level)

template prepareOutput*(r: var auto, level: LogLevel) =
  mixin activateOutput
  activateOutput(r.output, level)

template append*(o: var FileOutput, s: OutStr) =
  o.outFile.write s

template flushOutput*(o: var FileOutput) =
  # XXX: Uncommenting this triggers a strange compile-time error
  #      when multiple sinks are used.
  # doAssert o.outFile != nil
  o.outFile.flushFile

when defined(js):
  import jsconsole
  template append*(o: var StdOutOutput, s: OutStr) = console.log s
  template flushOutput*(o: var StdOutOutput)       = discard

  template append*(o: var StdErrOutput, s: OutStr) = console.error s
  template flushOutput*(o: var StdErrOutput)       = discard

else:
  template append*(o: var StdOutOutput, s: OutStr) =
    stdout.write s

  template flushOutput*(o: var StdOutOutput) =
    stdout.flushFile

  template append*(o: var StdErrOutput, s: OutStr) =
    stderr.write s

  template flushOutput*(o: var StdErrOutput) =
    stderr.flushFile

template append*(o: var StreamOutputRef, s: OutStr) =
  mixin append
  bind deref
  append(deref(o), s)

template flushOutput*(o: var StreamOutputRef) =
  mixin flushOutput
  bind deref
  flushOutput(deref(o))

when not defined(js):
  import faststreams/outputs

  proc initOutputStream*(LogRecord: type): auto =
    ## Return a distinct outputstream for the given LogRecord type that is reused
    ## for each log statement
    when not declared(outputs.consumeAll):
      # faststreams 0.3.0 and earlier are too buggy to reuse streams
      # preventing them from being reused :/
      memoryOutput()
    else:
      var outStream {.threadvar.}: OutputStreamHandle
      if outStream.s == nil:
        outStream = memoryOutput()
      outStream.s

  proc append(f: File, outStream: OutputStream) =
    when compiles(outStream.consumeAll):
      for span in outStream.consumeAll:
        discard writeBuffer(f, span.startAddr, span.len())
    else:
      outStream.consumeOutputs output:
        try:
          discard writeBuffer(f, unsafeAddr output[0], len output)
        except IOError as err:
          undeliveredMsg("Failed to write to output", output, err)

  template append*(o: var FileOutput, outStream: OutputStream) =
    o.outFile.append(outStream)

  template append*(o: var StdOutOutput, outStream: OutputStream) =
    system.stdout.append(outStream)

  template append*(o: var StdErrOutput, outStream: OutputStream) =
    system.stderr.append(outStream)

  proc append*(o: var DynamicOutput, outStream: OutputStream) =
    o.writer(o.currentRecordLevel, outStream.getOutput(string))

  template append*(output: var StreamOutputRef, outStream: OutputStream) =
    mixin append
    bind deref

    deref(output).append(outStream)

  proc append*(o: var PassThroughOutput, stream: OutputStream) =
    let str = stream.getOutput(string)

    for f in o.outputs.fields:
      append(f, str)

template colors*(o: StreamOutputRef): bool =
  bind deref
  deref(o).colors

template colors*(o: PassThroughOutput): bool =
  var res = false
  for f in o.outputs.fields:
    if f.colors:
      res = true
      break

  res

template append*(o: var SysLogOutput, s: OutStr) =
  let syslogLevel = case o.currentRecordLevel
                    of TRACE, DEBUG, NONE: LOG_DEBUG
                    of INFO:               LOG_INFO
                    of NOTICE:             LOG_NOTICE
                    of WARN:               LOG_WARNING
                    of ERROR:              LOG_ERR
                    of FATAL:              LOG_CRIT

  syslog(syslogLevel or LOG_PID, "%s", cstring(s))

template append*(o: var DynamicOutput, s: OutStr) =
  (o.writer)(o.currentRecordLevel, s)

template flushOutput*(o: var (SysLogOutput|DynamicOutput)) = discard

# The pass-through output just acts as a proxy, redirecting a single `append`
# call to multiple destinations:

proc flushOutput*(o: var PassThroughOutput) =
  for f in o.outputs.fields:
    flushOutput(f)

# We also define a macro form of `append` that takes multiple parameters and
# just expands to one `append` call per parameter:

macro append*(o: var AnyOutput,
              arg1, arg2: untyped,
              restArgs: varargs[untyped]): untyped =
  # Allow calling append with many arguments
  result = newStmtList()
  result.add newCall("append", o, arg1)
  result.add newCall("append", o, arg2)
  for arg in restArgs: result.add newCall("append", o, arg)

template shortName*(lvl: LogLevel): string =
  # Same-length strings make for nice alignment
  case lvl
  of TRACE: "TRC"
  of DEBUG: "DBG"
  of INFO:  "INF"
  of NOTICE:"NTC"  # Legacy: "NOT"
  of WARN:  "WRN"
  of ERROR: "ERR"
  of FATAL: "FAT"
  of NONE:  "   "

#
# When any of the output streams have multiple output formats, we need to
# create a single tuple holding all of the record types which will be passed
# by reference to the dynamically registered `appender` procs associated with
# the dynamic scope bindings (see dynamic_scope.nim for more details).
#
# All operations on such "composite" records are just dispatched to the
# individual concrete record types stored inside the tuple.
#
# The macro below will create such a composite record type for each of
# configured output stream.
#

proc sinkSpecsToCode(streamName: NimNode, sinks: seq[SinkSpec]): StreamCodeNodes =
  result.streamName = streamName
  result.outputsTuple = newTree(nnkTupleConstr)
  if sinks.len > 1:
    result.recordType = newTree(nnkTupleConstr)
    for i in 0 ..< sinks.len:
      result.recordType.add selectRecordType(result, sinks[i])
  else:
    result.recordType = selectRecordType(result, sinks[0])

template isStreamSymbolIMPL*(T: typed): bool = false

macro createStreamSymbol(name: untyped, RecordType: typedesc,
                         outputsTuple: typed): untyped =
  let tlsSlot = newIdentNode($name & "TlsSlot")
  let Record  = newIdentNode($name & "LogRecord")
  let outputs = newIdentNode($name & "Outputs")
  result = nnkStmtList.newTree()

  result.add quote do:
    type `name`* {.inject.} = object
    template isStreamSymbolIMPL*(S: type `name`): bool = true

    type `Record` = `RecordType`
    template Record*(S: type `name`): typedesc = `Record`

    var `outputs` = `outputsTuple`


    # The output objects are currently not GC-safe because they contain
    # strings (the `outPath` field). Since these templates are not used
    # in situations where these paths are modified, it's safe to provide
    # a gcsafe override until we switch to Nim's --newruntime.
    template outputs*(S: type `name`): auto = ({.gcsafe.}: addr `outputs`)[]
    template output* (S: type `name`): auto = ({.gcsafe.}: addr `outputs`[0])[]

    var `tlsSlot` {.threadvar.}: ptr BindingsFrame[`Record`]

    # If this tlsSlot accessor is allowed to be inlined and LTO employed, both
    #
    # Apple clang version 15.0.0 (clang-1500.1.0.2.5)
    # Target: arm64-apple-darwin23.2.0
    # Thread model: posix
    #
    # and
    #
    # Homebrew clang version 16.0.6
    # Target: arm64-apple-darwin23.2.0
    # Thread model: posix
    #
    # running on
    # ProductName:		macOS
    # ProductVersion:		14.2.1
    # BuildVersion:		23C71
    #
    # on a
    # hw.model: Mac14,3
    #
    # will do so, with proposeBlockAux() in nimbus-eth2 beacon_validators.nim
    # for
    #
    # notice "Block proposed",
    #  blockRoot = shortLog(blockRoot), blck = shortLog(forkyBlck),
    #  signature = shortLog(signature), validator = shortLog(validator)
    #
    # causing a SIGSEGV which lldb tracked to this aspect of TLS usage in
    # logAllDynamicProperties, where logAllDynamicProperties gets inlined
    # within proposeBlockAux.
    #
    # Based on CI symptoms, the same problem appears to occur on the Jenkins CI
    # fleet's M1 and M2 hosts. It has not been observed outside this macOS with
    # aarch64/ARM64 combination. With Nim 1.6, the stack trace looks like:
    #
    # Nim Compiler Version 1.6.18 [MacOSX: arm64]
    # Compiled at 2024-03-22
    # Copyright (c) 2006-2023 by Andreas Rumpf
    #
    # git hash: a749a8b742bd0a4272c26a65517275db4720e58a
    # active boot switches: -d:release
    #
    # Traceback (most recent call last, using override)
    # vendor/nim-chronos/chronos/internal/asyncfutures.nim(382) futureContinue
    # beacon_chain/validators/beacon_validators.nim(406) proposeBlock
    # vendor/nim-chronos/chronos/internal/asyncfutures.nim(382) futureContinue
    # beacon_chain/validators/beacon_validators.nim(419) proposeBlock
    # beacon_chain/validators/beacon_validators.nim(324) proposeBlockAux
    # vendor/nim-chronos/chronos/internal/asyncfutures.nim(382) futureContinue
    # beacon_chain/validators/beacon_validators.nim(398) proposeBlockAux
    # vendor/nimbus-build-system/vendor/Nim/lib/system/excpt.nim(631) signalHandler
    # SIGSEGV: Illegal storage access. (Attempt to read from nil?)
    #
    # using Nim 1.6 with refc and, with:
    #
    # Nim Compiler Version 2.0.3 [MacOSX: arm64]
    # Compiled at 2024-03-22
    # Copyright (c) 2006-2023 by Andreas Rumpf
    # git hash: e374759f29da733f3c404718c333f5f3cb5f332d
    # active boot switches: -d:release
    #
    # one sees
    #
    # Traceback (most recent call last, using override)
    # vendor/nim-chronos/chronos/internal/asyncfutures.nim(382) _ZN12asyncfutures14futureContinueE3refIN7futures26FutureBasecolonObjectType_EE
    # beacon_chain/validators/beacon_validators.nim(406) _ZN17beacon_validators12proposeBlockE3refIN9block_dag24BlockRefcolonObjectType_EE6uInt64
    # vendor/nim-chronos/chronos/internal/asyncfutures.nim(382) _ZN12asyncfutures14futureContinueE3refIN7futures26FutureBasecolonObjectType_EE
    # beacon_chain/validators/beacon_validators.nim(419) _ZN12proposeBlock12proposeBlockE3refIN7futures26FutureBasecolonObjectType_EE
    # beacon_chain/validators/beacon_validators.nim(324) _ZN15proposeBlockAux15proposeBlockAuxE8typeDescI3intE8typeDescI3intE3refIN17beacon_validators33AttachedValidatorcolonObjectType_EE3int5int323refIN9block_dag24BlockRefcolonObjectType_EE6uInt64
    # vendor/nim-chronos/chronos/internal/asyncfutures.nim(382) _ZN12asyncfutures14futureContinueE3refIN7futures26FutureBasecolonObjectType_EE
    # beacon_chain/validators/beacon_validators.nim(398) _ZN15proposeBlockAux15proposeBlockAuxE3refIN7futures26FutureBasecolonObjectType_EE
    # vendor/nimbus-build-system/vendor/Nim/lib/system/excpt.nim(631) signalHandler
    # vendor/nimbus-build-system/vendor/Nim/lib/system/stacktraces.nim(86) _ZN11stacktraces30auxWriteStackTraceWithOverrideE3varI6stringE
    # SIGSEGV: Illegal storage access. (Attempt to read from nil?)
    #
    # Chronicles commit there is:
    # commit ab3ab545be0b550cca1c2529f7e97fbebf5eba81
    # Date:   Fri Feb 16 11:34:42 2024 +0700
    #
    # and Chronos commit is:
    # commit 7b02247ce74d5ad5630013334f2e347680b02f65
    # Date:   Wed Feb 14 19:23:15 2024 +0200
    #
    # This is likely the same issue as documented by
    # https://github.com/status-im/nimbus-eth2/blob/33e34ee8bdaff625276b5826ba366edda7f7280e/beacon_chain/validators/beacon_validators.nim#L1190-L1318
    # which also contains similar stack traces and occurred under similar
    # circumstances. In particular it's also macOS aarch64-only, reported
    # specifically on macOS 14.2.1 and Xcode 15.1, like this issue.
    #
    # Splitting a let block allowed proceeding/working around it before, but
    # adding Electra to the nimbuus-eth2 ConsensusFork types appears to have
    # triggered it again more robustly, necessitating further investigation.
    #
    # https://github.com/status-im/nimbus-eth2/pull/6092 in macos-aarch64-repo2
    # branch and https://github.com/status-im/nimbus-eth2/pull/6104, which uses
    # the macos-aarch64-moreminimal branch, have more information.
    #
    # This workaround appears to be the least risky and performance-affecting
    # available in the short term. Disabling threading altogether avoids this
    # in the minimized repro sample, but isn't feasible in `nimbus-eth2`. The
    # test triggering this, `test_keymanager_api`, could be avoided on macOS,
    # when running on aarch64, but this might occur elsewhere, just silently.
    #
    # Using --tlsEmulation:on also appears to fix this, but can exact quite a
    # performance cost. This localizes the workaround's cost to this specific
    # observed issue's amelioration.
    proc tlsSlot*(S: type `name`): var ptr BindingsFrame[`Record`] {.noinline.} =
      `tlsSlot`

  if RecordType.kind == nnkTupleConstr:
    # Add helpers that forward arguments to each sink ensuring that each log
    # expression is evaluated only once (using an intermediate proc).
    when runtimeFilteringEnabled:
      # When runtime filtering is enabled, we must further check each sink - at
      # least one will be enabled when we reach here but we don't know how many
      result.add quote do:
        proc prepareOutput*(r: var `Record`, level: LogLevel, enabled: SinksBitmask) =
          mixin activateOutput

          var mask: uint8 = 1
          for f in r.fields:
            if (mask and enabled) > 0:
              activateOutput(f.output, level)
            mask = mask shl 1

        proc initLogRecord*(
            r: var `Record`,
            lvl: LogLevel,
            topics: string,
            name: string,
            enabled: SinksBitmask,
        ) =
          mixin initLogRecord
          var mask: uint8 = 1
          for f in r.fields:
            if (mask and enabled) > 0:
              initLogRecord(f, lvl, topics, name)
            mask = mask shl 1

        proc setProperty*(
            r: var `Record`, key: string, val: auto, enabled: SinksBitmask
        ) =
          mixin setProperty
          var mask: uint8 = 1
          for f in r.fields:
            if (mask and enabled) > 0:
              setProperty(f, key, val)
            mask = mask shl 1

        proc flushRecord*(r: var `Record`, enabled: SinksBitmask) =
          mixin flushRecord
          var mask: uint8 = 1
          for f in r.fields:
            if (mask and enabled) > 0:
              flushRecord(f)
            mask = mask shl 1

    else:
      result.add quote do:
        proc prepareOutput*(r: var `Record`, level: LogLevel) =
          mixin activateOutput
          for f in r.fields:
            activateOutput(f.output, level)

        proc initLogRecord*(
            r: var `Record`, lvl: LogLevel, topics: string, name: string
        ) =
          mixin initLogRecord
          for f in r.fields:
            initLogRecord(f, lvl, topics, name)

        proc setProperty*(r: var `Record`, key: string, val: auto) =
          mixin setProperty
          for f in r.fields:
            setProperty(f, key, val)

        proc flushRecord*(r: var `Record`) =
          mixin flushRecord
          for f in r.fields:
            flushRecord(f)

# This is a placeholder that will be overriden in the user code.
# XXX: replace that with a proper check that the user type requires
# an output resource.
proc createOutput(T: typedesc): byte = discard

func toModuleName(format: LogFormatPlugin): string =
  case format.string.toLowerAscii
  of "json":
    "chronicles/json_records"
  of "textlines":
    "chronicles/textlines"
  of "textblocks":
    "chronicles/textblocks"
  else:
    string format

const importedPlugins = CacheTable"importedPlugins"

func importSink(sink: SinkSpec): NimNode =
  if string(sink.format) notin importedPlugins:
    let res = parseStmt(
      "import $1 as $2\nexport $2" % [sink.format.toModuleName, sink.format.id]
    )
    importedPlugins[string sink.format] = res
    res
  else:
    newEmptyNode()

macro customLogStream*(streamDef: untyped): untyped =
  syntaxCheckStreamExpr streamDef
  let
    createOutput = bindSym("createOutput", brForceOpen)
    outputsTuple = newTree(nnkTupleConstr, newCall(createOutput, streamDef[1]))

  result = getAst(createStreamSymbol(streamDef[0], streamDef[1], outputsTuple))
  when defined(debugLogImpl):
    echo result.repr

macro logStream*(streamDef: untyped): untyped =
  # syntaxCheckStreamExpr streamDef
  let
    streamSinks = sinkSpecsFromNode(streamDef)
    streamName = streamDef[0]
    streamCode = sinkSpecsToCode(streamName, streamSinks)

  result = newStmtList()

  for sink in streamSinks:
    result.add importSink(sink)

  result.add getAst(
    createStreamSymbol(streamName, streamCode.recordType, streamCode.outputsTuple)
  )
  when defined(debugLogImpl):
    echo result.repr

macro createStreamRecordTypes: untyped =
  result = newStmtList()

  for i in 0 ..< config.streams.len:
    let stream = config.streams[i]

    for sink in stream.sinks:
      result.add importSink(sink)

    let
      streamName = newIdentNode(stream.name)
      streamCode = sinkSpecsToCode(streamName, stream.sinks)

    result.add getAst(
      createStreamSymbol(streamName, streamCode.recordType, streamCode.outputsTuple)
    )

    if i == 0:
      result.add quote do:
        template activeChroniclesStream*: typedesc = `streamName`

  when defined(debugLogImpl):
    echo result.repr

createStreamRecordTypes()
