import
  strutils, times, macros, options, os, terminal,
  faststreams/[textio, stdout], serialization, stew/shims/strings,
  dynamic_scope_types

when defined(js):
  type OutStr = cstring

else:
  type
    OutStr = openarray[char]

export
  LogLevel

type
  FileOutput* = object
    outFile*: File
    outPath: string
    mode: FileMode

  StdOutOutput* = object
  StdErrOutput* = object

  SysLogOutput* = object
    currentRecordLevel: LogLevel

  LogOutputStr* = OutStr

  DynamicOutput* = object
    currentRecordLevel: LogLevel
    writer*: proc (logLevel: LogLevel, logRecord: OutStr) {.gcsafe, raises: [Defect].}

  PassThroughOutput*[FinalOutputs: tuple] = object
    finalOutputs: FinalOutputs

  AnyFileOutput = FileOutput|StdOutOutput|StdErrOutput
  AnyOutput = AnyFileOutput|SysLogOutput|PassThroughOutput

  StreamOutputRef*[Stream; outputId: static[int]] = object

  StreamCodeNodes = object
    streamName: NimNode
    recordType: NimNode
    outputsTuple: NimNode

when defined(posix):
  {.pragma: syslog_h, importc, header: "<syslog.h>"}

  # proc openlog(ident: cstring, option, facility: int) {.syslog_h.}
  proc syslog(priority: int, format: cstring, msg: cstring) {.syslog_h.}
  # proc closelog() {.syslog_h.}

  # Unused syslog levels:
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

when not defined(js):
  proc open*(o: ptr FileOutput, path: string, mode = fmAppend): bool =
    if o.outFile != nil:
      close(o.outFile)
      o.outFile = nil
      o.outPath = ""

    createDir path.splitFile.dir
    result = open(o.outFile, path, mode)
    if result:
      o.outPath = path
      o.mode = mode

  proc open*(o: ptr FileOutput, file: File): bool =
    if o.outFile != nil:
      close(o.outFile)
      o.outPath = ""

    o.outFile = file

  proc open*(o: var FileOutput, path: string, mode = fmAppend): bool {.inline.} =
    open(o.addr, path, mode)

  proc open*(o: var FileOutput, file: File): bool {.inline.} =
    open(o.addr, file)

  proc openOutput(o: var FileOutput) =
    doAssert o.outPath.len > 0 and o.mode != fmRead
    createDir o.outPath.splitFile.dir
    o.outFile = open(o.outPath, o.mode)

proc createFileOutput(path: string, mode: FileMode): FileOutput =
  result.mode = mode
  result.outPath = path

template ignoreIOErrors(body: untyped) =
  try: body
  except IOError: discard

proc logLoggingFailure*(msg: cstring, ex: ref Exception) =
  ignoreIOErrors:
    stderr.writeLine("[Chronicles] Log message not delivered: ", msg)
    if ex != nil: stderr.writeLine(ex.msg)

proc undeliveredMsg(reason: string, logMsg: OutStr, ex: ref Exception) =
  const
    lineTag = "[Chronicles] "
    infoMsg = ". Log message not delivered: "

  var msg = newStringOfCap(lineTag.len + reason.len + infoMsg.len + logMsg.len)
  msg.add lineTag
  msg.add reason
  msg.add infoMsg
  msg.add logMsg

  logLoggingFailure(cstring(msg), ex)

proc undeliveredMsg(reason: string, logMsg: openArray[byte], ex: ref Exception) =
  var charArray = cast[ptr UncheckedArray[char]](unsafeAddr logMsg[0])
  undeliveredMsg(reason, toOpenArray(charArray, 0, logMsg.len - 1), ex)

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
  var outputId = 0
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
    outputId = s.outputsTuple.len
    s.outputsTuple.add newTree(nnkObjConstr, bnd"DynamicOutput")

  case dst.kind
  of oStdOut: bnd"StdOutOutput"
  of oStdErr: bnd"StdErrOutput"
  of oSysLog: bnd"SysLogOutput"
  of oFile, oDynamic:
    newTree(nnkBracketExpr,
            bnd"StreamOutputRef", s.streamName, newLit(outputId))

template id(fmt: LogFormatPlugin): string =
  "F" & toHex(string fmt)

proc selectRecordType(s: var StreamCodeNodes, sink: SinkSpec): NimNode =
  # This proc translates the SinkSpecs loaded in the `options` module
  # to their corresponding LogRecord types.
  #
  # We must use buffered output if any of the following is true:
  #
  # * Threading is enabled
  #   (we don't wont races between the `setProperty` calls)
  #
  # * The syslog output is used or we are comping to JavaScript
  #   (we must send a single sting to the output)
  #
  # * Multiple destinations are present
  #   (we don't want to compute the output multiple times)
  #
  #
  # The faststreams-based outputs (such as json) are already buffered,
  # so we don't need to handle them in a special way.

  result = newTree(nnkBracketExpr,
                   newTree(nnkDotExpr, ident(sink.format.id), ident("LogRecord")))

  # Check if a buffered output is needed
  if false:
     #defined(js) or
     #sink.destinations.len > 1 or
     #sink.destinations[0].kind in {oSyslog,oDynamic} or
     #compileOption("threads"):

    # Here, we build the list of outputs as a tuple
    var outputsTuple = newTree(nnkTupleConstr)
    for dst in sink.destinations:
      outputsTuple.add selectOutputType(s, dst)

    var outputType = bnd"PassThroughOutput"
    result.add newTree(nnkBracketExpr, outputType, outputsTuple)
  else:
    result.add selectOutputType(s, sink.destinations[0])

  result.add newIdentNode($sink.timestamps)

  # Set the color scheme for the record types that require it
  var colorScheme = sink.colorScheme
  when not defined(windows):
    # `NativeColors' means `AnsiColors` on non-Windows platforms:
    if colorScheme == NativeColors:
      colorScheme = AnsiColors
  result.add newIdentNode($colorScheme)

# The `append` and `flushOutput` functions implement the actual writing
# to the log destinations (which we call Outputs).
# The LogRecord types are parametric on their Output and this is how we
# can support arbitrary combinations of log formats and destinations.

template activateOutput*(o: var (StdOutOutput|StdErrOutput|OutputStream),
                         level: LogLevel) =
  discard

template activateOutput*(o: var FileOutput, level: LogLevel) =
  if o.outFile == nil: openOutput(o)

template activateOutput*(o: var StreamOutputRef, level: LogLevel) =
  activateOutput(deref(o), level)

template activateOutput*(o: var (SysLogOutput|DynamicOutput), level: LogLevel) =
  o.currentRecordLevel = level

template activateOutput*(o: var PassThroughOutput, level: LogLevel) =
  for f in o.finalOutputs.fields:
    activateOutput(f, level)

template prepareOutput*(r: var auto, level: LogLevel) =
  mixin activateOutput

  when r is tuple:
    for f in r.fields:
      activateOutput(f.output, level)
  else:
    activateOutput(r.output, level)

proc initOutputStream*(LogRecord: type): auto =
  when LogRecord.OutputKind is StdOutOutput:
    var outStream {.threadvar.}: OutputStreamHandle
    if outStream.s == nil:
      outStream = memoryOutput()
    outStream.s
  else:
    default(T.OutputKind)

proc writeOutStr(f: File, s: OutStr) =
  # TODO: error handling
  discard f.writeBuffer(unsafeAddr s, s.len)

template append*(o: var FileOutput, s: OutStr) =
  writeOutStr(o.outFile, s)

template flushOutput*(o: var FileOutput) =
  # XXX: Uncommenting this triggers a strange compile-time error
  #      when multiple sinks are used.
  # doAssert o.outFile != nil
  flushFile o.outFile

template getOutputStream(o: FileOutput): File =
  o.outFile

when defined(js):
  template append*(o: var StdOutOutput, s: OutStr) = console.log s
  template flushOutput*(o: var StdOutOutput)       = discard

  template append*(o: var StdErrOutput, s: OutStr) = console.error s
  template flushOutput*(o: var StdErrOutput)       = discard

else:
  template append*(o: var StdOutOutput, s: OutStr) =
    try: writeOutStr(stdout, s)
    except IOError as err:
      undeliveredMsg("Failed to write to stdout", s, err)

  template flushOutput*(o: var StdOutOutput) =
    ignoreIOErrors(stdout.flushFile)

  template append*(o: var StdErrOutput, s: OutStr) =
    ignoreIOErrors(stderr.writeOutStr s)

  template flushOutput*(o: var StdErrOutput) =
    ignoreIOErrors(stderr.flushFile)

template getOutputStream(o: StdOutOutput): File = stdout
template getOutputStream(o: StdErrOutput): File = stderr

template append*(o: var StreamOutputRef, s: OutStr) = append(deref(o), s)
template flushOutput*(o: var StreamOutputRef)       = flushOutput(deref(o))

import
  faststreams/buffers

proc flushOutput*(OutputKind: type, outStream: OutputStream) =
  outStream.consumeOutputs output:
    when OutputKind is StdOutOutput|StdErrOutput:
      const outputNickName = when OutputKind is StdOutOutput:
        "stdout"
      else:
        "stderr"

      let outFile = when OutputKind is StdOutOutput:
        system.stdout
      else:
        system.stderr

      try:
        discard writeBuffer(outFile, unsafeAddr output[0], len output)
      except IOError as err:
        undeliveredMsg("Failed to write to " & outputNickName, output, err)

    else:
      # TODO
      echo "Flushing"

template append*(o: OutputStream, s: string) =
  write(o, s)

template append*(o: OutputStream, s: openarray[char]) =
  write(o, s)

template getOutputStream(o: StreamOutputRef): File =
  getOutputStream(deref(o))

proc toCstring(s: OutStr): cstring =
  static: assert s is openarray[char]
  cast[cstring](s)

template append*(o: var SysLogOutput, s: OutStr) =
  let syslogLevel = case o.currentRecordLevel
                    of TRACE, DEBUG, NONE: LOG_DEBUG
                    of INFO:               LOG_INFO
                    of NOTICE:             LOG_NOTICE
                    of WARN:               LOG_WARNING
                    of ERROR:              LOG_ERR
                    of FATAL:              LOG_CRIT

  syslog(syslogLevel or LOG_PID, "%s", s.toCstring)

template append*(o: var DynamicOutput, s: OutStr) =
  if o.writer.isNil:
    undeliveredMsg "A writer was not configured for a dynamic log output device", s, nil
  else:
    (o.writer)(o.currentRecordLevel, s)

template flushOutput*(o: var (SysLogOutput|DynamicOutput)) = discard

# The pass-through output just acts as a proxy, redirecting a single `append`
# call to multiple destinations:

proc append*(o: var PassThroughOutput, str: OutStr) =
  for f in o.finalOutputs.fields:
    append(f, str)

template flushOutput*(o: var PassThroughOutput) =
  for f in o.finalOutputs.fields:
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

import
  stew/objects

let timezone = toArray(6, now().format("zzz"))
const rfcFormat = initTimeFormat "yyyy-MM-dd HH:mm:ss'.'fffzzz"

template rfcTimestamp: string =
  now().format(rfcFormat)

template epochTimestamp: string =
  formatFloat(epochTime(), ffDecimal, 6)

template writeTs*(record) =
  when record.timestamps != NoTimestamps:
    append record.output, " "
    when record.timestamps == RfcTime:
      let t = now()
      writeText record.output, t.year
      write record.output, '-'
      writeText record.output, t.month.ord
      write record.output, '-'
      writeText record.output, t.monthday
      write record.output, ' '
      writeText record.output, t.hour
      write record.output, ':'
      writeText record.output, t.minute
      write record.output, ':'
      writeText record.output, t.second
      write record.output, '.'
      writeText record.output, t.nanosecond div 1000000
      write record.output, timezone
    else:
      when record.output is OutputStream:
        record.output.writeText epochTime()
      else:
        append record.output, epochTimestamp()

template timestamp*(record): string =
  when record.timestamp == RfcTime:
    rfcTimestamp()
  else:
    epochTimestamp()

#
# color and style support functions
#

const
  propColor* = fgBlue
  topicsColor* = fgYellow

template setFgColor*(s: OutputStream,
                     colorScheme: static ColorScheme,
                     color, brightness) =
  when colorScheme == AnsiColors:
    s.write(ansiForegroundColorCode(color, brightness)

template applyStyle*(s: OutputStream, colorScheme: static ColorScheme,
                     style) =
  when colorScheme == AnsiColors:
    s.write ansiStyleCode(style)

template setFgColor*(record, color, brightness) =
  when record.colors == AnsiColors:
    append(record.output, ansiForegroundColorCode(color, brightness))
  elif record.colors == NativeColors:
    setForegroundColor(getOutputStream(record.output), color, brightness)

template resetColors*(record) =
  when record.colors == AnsiColors:
    append(record.output, ansiResetCode)
  elif record.colors == NativeColors:
    resetAttributes(getOutputStream(record.output))

template applyStyle*(record, style) =
  when record.colors == AnsiColors:
    append(record.output, ansiStyleCode(style))
  elif record.colors == NativeColors:
    setStyle(getOutputStream(record.output), {style})

template levelToStyle*(lvl: LogLevel): untyped =
  # Bright Black is gray
  # Light green doesn't display well on white consoles
  # Light yellow doesn't display well on white consoles
  # Light cyan is darker than green

  case lvl
  of TRACE: (fgWhite, false)
  of DEBUG: (fgBlack, true) # Bright Black is gray
  of INFO:  (fgCyan, true)
  of NOTICE:(fgMagenta, false)
  of WARN:  (fgYellow, false)
  of ERROR: (fgRed, true)
  of FATAL: (fgRed, false)
  of NONE:  (fgWhite, false)

template shortName*(lvl: LogLevel): string =
  # Same-length strings make for nice alignment
  case lvl
  of TRACE:   "TRC"
  of DEBUG:   "DBG"
  of INFO:    "INF"
  of NOTICE:  "NOT"
  of WARN:    "WRN"
  of ERROR:   "ERR"
  of FATAL:   "FAT"
  of NONE:    "   "

proc `$`*(ex: ref Exception): string =
  result = ""
  result &= "exception " & $ex.name & "\n"
  result &= "msg \"" & $ex.msg & "\"\n"
  when not defined(js) and not defined(nimscript) and hostOS != "standalone":
    result &= "location " & getStackTrace(ex).strip

# TODO
template writeLogLevel*(s: OutputStream,
                        colorScheme: static ColorScheme,
                        lvl: LogLevel) =
  when colorScheme != NoColors:
    let (color, bright) = levelToStyle(lvl)
    setFgColor(s, colorScheme, color, bright)

  s.write shortName(lvl)

  resetColors(s, colorScheme)

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

proc sinkSpecsToCode(streamName: NimNode,
                     sinks: seq[SinkSpec]): StreamCodeNodes =
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

  result = quote:
    type `name`* {.inject.} = object
    template isStreamSymbolIMPL*(S: type `name`): bool = true

    type `Record` = `RecordType`
    template Record*(S: type `name`): typedesc = `Record`

    when `Record` is tuple:
      template initLogRecord*(r: var `Record`, lvl: LogLevel,
                              topics: string, name: string) =
        for f in r.fields: initLogRecord(f, lvl, topics, name)

      template setFirstProperty*(r: var `Record`, key: string, val: auto) =
        for f in r.fields: setFirstProperty(f, key, val)

      template setProperty*(r: var `Record`, key: string, val: auto) =
        for f in r.fields: setProperty(f, key, val)

      template flushRecord*(r: var `Record`) =
        for f in r.fields: flushRecord(f)

    var `tlsSlot` {.threadvar.}: ptr BindingsFrame[`Record`]
    template tlsSlot*(S: type `name`): auto = `tlsSlot`

    var `outputs` = `outputsTuple`

    # The output objects are currently not GC-safe because they contain
    # strings (the `outPath` field). Since these templates are not used
    # in situations where these paths are modified, it's safe to provide
    # a gcsafe override until we switch to Nim's --newruntime.
    template outputs*(S: type `name`): auto = ({.gcsafe.}: addr `outputs`)[]
    template output* (S: type `name`): auto = ({.gcsafe.}: addr `outputs`[0])[]

# This is a placeholder that will be overriden in the user code.
# XXX: replace that with a proper check that the user type requires
# an output resource.
proc createOutput(T: typedesc): byte = discard

macro customLogStream*(streamDef: untyped): untyped =
  syntaxCheckStreamExpr streamDef
  let
    createOutput = bindSym("createOutput", brForceOpen)
    outputsTuple = newTree(nnkTupleConstr, newCall(createOutput, streamDef[1]))

  result = getAst(createStreamSymbol(streamDef[0],
                                     streamDef[1],
                                     outputsTuple))

macro logStream*(streamDef: untyped): untyped =
  # syntaxCheckStreamExpr streamDef
  let
    streamSinks = sinkSpecsFromNode(streamDef)
    streamName  = streamDef[0]
    streamCode = sinkSpecsToCode(streamName, streamSinks)

  result = getAst(createStreamSymbol(streamName,
                                     streamCode.recordType,
                                     streamCode.outputsTuple))

when defined(windows) and false:
  # This is some experimental code that enables native ANSI color codes
  # support on Windows 10 (it has been confirmed to work, but the feature
  # detection should be done in a more robust way).
  # Please note that Nim's terminal module already has some provisions for
  # enabling the ANSI codes through calling `enableTrueColors`, but this
  # relies internally on `getVersionExW` which doesn't always return the
  # correct Windows version (the returned value depends on the manifest
  # file shipped with the application). For more info, see MSDN:
  # https://msdn.microsoft.com/en-us/library/windows/desktop/ms724451(v=vs.85).aspx
  import winlean
  const ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004

  proc getConsoleMode(hConsoleHandle: Handle, dwMode: ptr DWORD): WINBOOL{.
      stdcall, dynlib: "kernel32", importc: "GetConsoleMode".}

  proc setConsoleMode(hConsoleHandle: Handle, dwMode: DWORD): WINBOOL{.
      stdcall, dynlib: "kernel32", importc: "SetConsoleMode".}

  var mode: DWORD = 0
  if getConsoleMode(getStdHandle(STD_OUTPUT_HANDLE), addr(mode)) != 0:
    mode = mode or ENABLE_VIRTUAL_TERMINAL_PROCESSING
    if setConsoleMode(getStdHandle(STD_OUTPUT_HANDLE), mode) != 0:
      discard
      # echo "ANSI MODE ENABLED"

macro createStreamRecordTypes: untyped =
  result = newStmtList()
  var importedPlugins = newSeq[string]()

  for i in 0 ..< config.streams.len:
    let stream = config.streams[i]

    for sink in stream.sinks:
      if importedPlugins.find(sink.format.id) == -1:
        result.add parseStmt("import $1 as $2\nexport $2" %
                             [sink.format.string, sink.format.id])
        importedPlugins.add sink.format.id

    let
      streamName = newIdentNode(stream.name)
      streamCode = sinkSpecsToCode(streamName, stream.sinks)

    result.add getAst(createStreamSymbol(streamName,
                                         streamCode.recordType,
                                         streamCode.outputsTuple))

    if i == 0:
      result.add quote do:
        template activeChroniclesStream*: typedesc = `streamName`

  echo result.repr

createStreamRecordTypes()

