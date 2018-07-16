import
  times, macros, options, terminal, os

export
  LogLevel

type
  FileOutput* = object
    outFile: File
    outPath: string
    mode: FileMode

  StdOutOutput* = object
  StdErrOutput* = object
  SysLogOutput* = object

  BufferedOutput*[FinalOutputs: tuple] = object
    buffer: string

  AnyOutput = FileOutput|StdOutOutput|StdErrOutput|
              SysLogOutput|BufferedOutput

  TextLineRecord*[Output;
                  timestamps: static[TimestampsScheme],
                  colors: static[ColorScheme]] = object
    output: Output

  TextBlockRecord*[Output;
                   timestamps: static[TimestampsScheme],
                   colors: static[ColorScheme]] = object
    output: Output

  JsonRecord*[Output; timestamps: static[TimestampsScheme]] = object
    output: Output

  StreamOutputRef*[Stream; outputId: static[int]] = object

  StreamCodeNodes = object
    streamName: NimNode
    recordType: NimNode
    outputsTuple: NimNode

# XXX: `bindSym` is currently broken and doesn't return proper type symbols
# (the resulting nodes should have a `tyTypeDesc` type, but they don't)
# Until this is fixed, use regular ident nodes to work-around the problem.
template bnd(s): NimNode =
  # bindSym(s)
  newIdentNode(s)

template deref(so: StreamOutputRef): auto =
  outputs(so.Stream)[so.outputId]

proc open*(o: var FileOutput, path: string, mode = fmAppend): bool =
  if o.outFile != nil:
    close(o.outFile)
    o.outFile = nil
    o.outPath = ""

  createDir path.splitFile.dir
  result = open(o.outFile, path, mode)
  if result:
    o.outPath = path
    o.mode = mode

proc openOutput(o: var FileOutput) =
  assert o.outPath.len > 0 and o.mode != fmRead
  createDir o.outPath.splitFile.dir
  o.outFile = open(o.outPath, o.mode)

proc createFileOutput(path: string, mode: FileMode): FileOutput =
  result.mode = mode
  result.outPath = path

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
#    for this rule is the 'default' stream, for which the log file will be
#    assigned the name of the application binary.
#
# 2. If more than one unnamed file outputs exist for a given stream,
#    chronicles will add an index such as '.2.log', '.3.log' .. '.N.log'
#    to the final file name.
#

proc selectLogName(stream: string, outputId: int): string =
  result = if stream != defaultChroniclesStreamName: stream
           else: getAppFilename().splitFile.name

  if outputId > 1: result.add("." & $outputId)
  result.add ".log"

proc selectOutputType(s: var StreamCodeNodes, dst: LogDestination): NimNode =
  var outputId = 0
  if dst.kind == toFile:
    outputId = s.outputsTuple.len

    let mode = if dst.truncate: bindSym"fmWrite"
               else: bindSym"fmAppend"

    let fileName = if dst.filename.len > 0: newLit(dst.filename)
                   else: newCall(bindSym"selectLogName",
                                 newLit($s.streamName), newLit(outputId))

    s.outputsTuple.add newCall(bindSym"createFileOutput", fileName, mode)

  case dst.kind
  of toStdOut: bnd"StdOutOutput"
  of toStdErr: bnd"StdErrOutput"
  of toSysLog: bnd"SysLogOutput"
  of toFile: newTree(nnkBracketExpr,
                     bnd"StreamOutputRef", s.streamName, newLit(outputId))

proc selectRecordType(s: var StreamCodeNodes, sink: SinkSpec): NimNode =
  # This proc translates the SinkSpecs loaded in the `options` module
  # to their corresponding LogRecord types.
  #
  # When there is just one log destination, the record type
  # will be a simple instantiation such as JsonRecord[StdOutOutput]
  #
  # But if multiple log destinations are present or if the Syslog
  # output is used, then the resulting type will be
  # BufferedOutput[(Output1, Output2, ...)]
  #

  # Determine the head symbol of the instantiation
  let RecordType = case sink.format
                   of json: bnd"JsonRecord"
                   of textLines: bnd"TextLineRecord"
                   of textBlocks: bnd"TextBlockRecord"

  result = newTree(nnkBracketExpr, RecordType)

  # Check if a buffered output is needed
  if sink.destinations.len > 1 or sink.destinations[0].kind == toSyslog:
    var bufferredOutput = newTree(nnkBracketExpr,
                                  bnd"BufferedOutput")
    # Here, we build the list of outputs as a tuple
    var outputsTuple = newTree(nnkTupleConstr)
    for dst in sink.destinations:
      outputsTuple.add selectOutputType(s, dst)

    bufferredOutput.add outputsTuple
    result.add bufferredOutput
  else:
    result.add selectOutputType(s, sink.destinations[0])

  result.add newIdentNode($sink.timestamps)

  # Set the color scheme for the record types that require it
  if sink.format != json:
    var colorScheme = sink.colorScheme
    when not defined(windows):
      # `NativeColors' means `AnsiColors` on non-Windows platforms:
      if colorScheme == NativeColors: colorScheme = AnsiColors
    result.add newIdentNode($colorScheme)

# The `append` and `flushOutput` functions implement the actual writing
# to the log destinations (which we call Outputs).
# The LogRecord types are parametric on their Output and this is how we
# can support arbitrary combinations of log formats and destinations.

template append*(o: var FileOutput, s: string) =
  if o.outFile == nil: openOutput(o)
  o.outFile.write s

template flushOutput*(o: var FileOutput) =
  assert o.outFile != nil
  o.outFile.flushFile

template append*(o: var StdOutOutput, s: string) = stdout.write s
template flushOutput*(o: var StdOutOutput)       = stdout.flushFile

template append*(o: var StdErrOutput, s: string) = stderr.write s
template flushOutput*(o: var StdErrOutput)       = stderr.flushFile

template getOutputStream(o: StdOutOutput): File = stdout
template getOutputStream(o: StdErrOutput): File = stderr

template append*(o: var StreamOutputRef, s: string) = append(deref(o), s)
template flushOutput*(o: var StreamOutputRef)       = flushOutput(deref(o))

# The buffered Output works in a very simple way. The log message is first
# buffered into a sting and when it needs to be flushed, we just instantiate
# each of the Output types and call `append` and `flush` on the instance:

template append*(o: var BufferedOutput, s: string) =
  o.buffer.add(s)

template flushOutput*(o: var BufferedOutput) =
  var finalOuputs: o.FinalOutputs
  for finalOutput in finalOuputs.fields:
    append(finalOutput, o.buffer)
    flushOutput(finalOutput)

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

# The formatting functions defined for each LogRecord type are carefully
# written to expand to multiple calls to `append` that can be merged by
# a simple term-rewriting rule. In the final code, any consequtive appends
# using literal values will be merged together into a single `write` call
# to their destination object:

template optimizeLogWrites*{
  write(f, x)
  write(f, y)
}(x, y: string{lit}, f: File) =
  write(f, x & y)

template optimizeBufferAppends*{
  add(s, x)
  add(s, y)
}(x, y: string{lit}, s: string) =
  add(s, x & y)

proc appendRfcTimestamp(o: var auto) =
  var ts = now()
  append(o, $ts.year)
  append(o, "-")
  append(o, intToStr(ord(ts.month), 2))
  append(o, "-")
  append(o, intToStr(ts.monthday, 2))
  append(o, " ")
  append(o, intToStr(ts.hour, 2))
  append(o, ":")
  append(o, intToStr(ts.minute, 2))
  append(o, ":")
  append(o, intToStr(ts.second, 2))

template writeTs(record) =
  when record.timestamps == RfcTime:
    appendRfcTimestamp(record.output)
  else:
    append(record.output, $epochTime())

const
  propColor = if defined(windows): fgCyan else: fgBlue
  topicsColor = fgYellow

template fgColor(record, color, brightness) =
  when record.colors == AnsiColors:
    append(record.output, ansiForegroundColorCode(color, brightness))
  elif record.colors == NativeColors:
    setForegroundColor(getOutputStream(record.output), color, brightness)

template resetColors(record) =
  when record.colors == AnsiColors:
    append(record.output, ansiResetCode)
  elif record.colors == NativeColors:
    resetAttributes(getOutputStream(record.output))

template applyStyle(record, style) =
  when record.colors == AnsiColors:
    append(record.output, ansiStyleCode(style))
  elif record.colors == NativeColors:
    setStyle(getOutputStream(record.output), {style})

template appendLogLevelMarker(r: var auto, lvl: LogLevel) =
  append(r.output, "[")

  when r.colors != NoColors:
    let (color, bright) = case lvl
                          of DEBUG: (fgGreen, true)
                          of INFO:  (fgGreen, false)
                          of NOTICE:(fgYellow, false)
                          of WARN:  (fgYellow, true)
                          of ERROR: (fgRed, false)
                          of FATAL: (fgRed, true)
                          else:     (fgWhite, false)

    fgColor(r, color, bright)

  append(r.output, $lvl)
  resetColors(r)
  append(r.output, "] ")

template appendTopics(r: var auto, topics: string) =
  when topics.len > 0:
    append(r.output, "[")
    fgColor(r, topicsColor, true)
    append(r.output, topics)
    resetColors(r)
    append(r.output, "] ")

#
# A LogRecord is a single "logical line" in the output.
#
# 1. It's instantiated by the log statement.
#
# 2. It's initialized with a call to `initLogRecord`.
#
# 3. Zero or more calls to `setFirstProperty` and `setPropery` are
#    executed with the current lixical and dynamic bindings.
#
# 4. Finally, `flushRecord` should wrap-up the record and flush the output.
#

#
# Text line records:
#

template initLogRecord*(r: var TextLineRecord,
                        lvl: LogLevel,
                        topics: string,
                        name: string) =
  when r.timestamps != NoTimestamps:
    append(r.output, "[")
    writeTs(r)
    append(r.output, "] ")

  appendLogLevelMarker(r, lvl)
  appendTopics(r, topics)

  applyStyle(r, styleBright)
  append(r.output, name)
  resetColors(r)

template setPropertyImpl(r: var TextLineRecord, key: string, val: auto) =
  let valText = $val
  var
    escaped: string
    valueToWrite: ptr string

  if valText.find(NewLines) == -1:
    valueToWrite = unsafeAddr valText
  else:
    escaped = newStringOfCap(valText.len * valText.len div 8)
    addQuoted(escaped, valText)
    valueToWrite = addr escaped

  fgColor(r, propColor, false)
  append(r.output, key)
  append(r.output, "=")
  applyStyle(r, styleBright)
  append(r.output, valueToWrite[])
  resetColors(r)

template setFirstProperty*(r: var TextLineRecord, key: string, val: auto) =
  append(r.output, " (")
  setPropertyImpl(r, key, val)

template setProperty*(r: var TextLineRecord, key: string, val: auto) =
  append(r.output, ", ")
  setPropertyImpl(r, key, val)

template flushRecord*(r: var TextLineRecord) =
  append(r.output, ")\n")
  flushOutput(r.output)

#
# Textblock records:
#

template initLogRecord*(r: var TextBlockRecord,
                        lvl: LogLevel,
                        topics: string,
                        name: string) =
  when r.timestamps != NoTimestamps:
    append(r.output, "[")
    writeTs(r)
    append(r.output, "] ")

  appendLogLevelMarker(r, lvl)
  appendTopics(r, topics)
  applyStyle(r, styleBright)
  append(r.output, name & "\n")
  resetColors(r)

template setFirstProperty*(r: var TextBlockRecord, key: string, val: auto) =
  let valText = $val

  append(r.output, textBlockIndent)
  fgColor(r, propColor, false)
  append(r.output, key)
  append(r.output, ": ")
  applyStyle(r, styleBright)

  if valText.find(NewLines) == -1:
    append(r.output, valText)
    append(r.output, "\n")
  else:
    # XXX: This should be a const, but the compiler fails with an ICE
    let indentNextLine = static("\n" & textBlockIndent & repeat(' ', key.len + 2))
    for line in splitLines(valText):
      append(r.output, line)
      append(r.output, indentNextLine)

  resetColors(r)

template setProperty*(r: var TextBlockRecord, key: string, val: auto) =
  setFirstProperty(r, key, val)

template flushRecord*(r: var TextBlockRecord) =
  append(r.output, "\n")
  flushOutput(r.output)

#
# JSON records:
#

import json

template jsonEncode(x: auto): string = $(%x)

template initLogRecord*(r: var JsonRecord,
                        lvl: LogLevel,
                        topics: string,
                        name: string) =
  append(r.output, """{"msg": """ & jsonEncode(name) &
                   """, "lvl": """ & jsonEncode($lvl))

  if topics.len > 0:
    append(r.output, """, "topics": """ &  jsonEncode(topics))

  when r.timestamps != NoTimestamps:
    append(r.output, """, "ts": """")
    writeTs(r)
    append(r.output, "\"")

template setFirstProperty*(r: var JsonRecord, key: string, val: auto) =
  append(r.output, ", ")
  append(r.output, jsonEncode(key))
  append(r.output, ": ")
  append(r.output, jsonEncode(val))

template setProperty*(r: var JsonRecord, key: string, val: auto) =
  setFirstProperty(r, key, val)

template flushRecord*(r: var JsonRecord) =
  append(r.output, "}\n")
  flushOutput(r.output)

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

import dynamic_scope_types

template isStreamSymbolIMPL*(T: typed): bool = false

import typetraits

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
    template outputs*(S: type `name`): auto = `outputs`
    template output* (S: type `name`): auto = `outputs`[0]

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

macro createStreamRecordTypes: untyped =
  result = newStmtList()

  for i in 0 ..< config.streams.len:
    let
      s = config.streams[i]
      streamName = newIdentNode(s.name)
      streamCode = sinkSpecsToCode(streamName, s.sinks)

    result.add getAst(createStreamSymbol(streamName,
                                         streamCode.recordType,
                                         streamCode.outputsTuple))

    if i == 0:
      result.add quote do:
        template activeChroniclesStream*: typedesc = `streamName`

createStreamRecordTypes()

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
