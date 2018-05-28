import
  times, strutils, macros, options, terminal

export
  LogLevel

type
  FileOutput*[outputId: static[int], truncate: static[bool]] = object
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

# XXX: `bindSym` is currently broken and doesn't return proper type symbols
# (the resulting nodes should have a `tyTypeDesc` type, but they don't)
# Until this is fixed, use regular ident nodes to work-around the problem.
template bnd(s): NimNode =
  # bindSym(s)
  newIdentNode(s)

proc selectOutputType(dst: LogDestination): NimNode =
  case dst.kind
  of toStdOut: bnd"StdOutOutput"
  of toStdErr: bnd"StdErrOutput"
  of toSysLog: bnd"SysLogOutput"
  of toFile:   newTree(nnkBracketExpr, bnd"FileOutput",
                                       newLit(dst.outputId),
                                       newLit(dst.truncate))

proc selectRecordType(sink: SinkSpec): NimNode =
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
  let recordType = case sink.format
                   of json: bnd"JsonRecord"
                   of textLines: bnd"TextLineRecord"
                   of textBlocks: bnd"TextBlockRecord"

  result = newTree(nnkBracketExpr, recordType)

  # Check if a buffered output is needed
  if sink.destinations.len > 1 or sink.destinations[0].kind == toSyslog:
    var bufferredOutput = newTree(nnkBracketExpr,
                                  bnd"BufferedOutput")
    # Here, we build the list of outputs as a tuple
    var outputsTuple = newTree(nnkPar)
    for dst in sink.destinations:
      outputsTuple.add selectOutputType(dst)

    bufferredOutput.add outputsTuple
    result.add bufferredOutput
  else:
    result.add selectOutputType(sink.destinations[0])

  result.add newIdentNode($sink.timestamps)

  # Set the color scheme for the record types that require it
  if sink.format != json:
    result.add newIdentNode($sink.colorScheme)

var
  fileOutputs: array[config.totalFileOutputs, File]

# The `append` and `flushOutput` functions implement the actual writing
# to the log destinations (which we call Outputs).
# The LogRecord types are parametric on their Output and this is how we
# can support arbitrary combinations of log formats and destinations.

template append*(o: var FileOutput, s: string) = fileOutputs[o.outputId].write s
template flushOutput*(o: var FileOutput)       = fileOutputs[o.outputId].flushFile

template append*(o: var StdOutOutput, s: string) = stdout.write s
template flushOutput*(o: var StdOutOutput)       = stdout.flushFile

template append*(o: var StdErrOutput, s: string) = stderr.write s
template flushOutput*(o: var StdErrOutput)       = stderr.flushFile

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

template appendLogLevelMarker(r: var auto, lvl: LogLevel) =
  append(r.output, "[")

  when r.colors == AnsiColors:
    let (color, bright) = case lvl
                          of DEBUG: (fgGreen, true)
                          of INFO:  (fgGreen, false)
                          of NOTICE:(fgYellow, false)
                          of WARN:  (fgYellow, true)
                          of ERROR: (fgRed, false)
                          of FATAL: (fgRed, true)
                          else:     (fgWhite, false)

    append(r.output, ansiForegroundColorCode(color, bright))

  append(r.output, $lvl)

  when r.colors == AnsiColors:
    append(r.output, ansiResetCode)

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

template initLogRecord*(r: var TextLineRecord, lvl: LogLevel, name: string) =
  when r.timestamps != NoTimestamps:
    append(r.output, "[")
    writeTs(r)
    append(r.output, "] ")

  appendLogLevelMarker(r, lvl)
  when r.colors == AnsiColors: append(r.output, ansiStyleCode(styleBright))
  append(r.output, name)
  when r.colors == AnsiColors: append(r.output, ansiResetCode)

template setPropertyImpl(r: var TextLineRecord, key: string, val: auto) =
  when r.colors == AnsiColors:
    append(r.output, ansiForegroundColorCode(fgBlue, false))

  append(r.output, key)
  append(r.output, "=")

  when r.colors == AnsiColors:
    append(r.output, static ansiStyleCode(styleBright))

  append(r.output, $val)

  when r.colors == AnsiColors:
    append(r.output, ansiResetCode)

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

template initLogRecord*(r: var TextBlockRecord, lvl: LogLevel, name: string) =
  when r.timestamps != NoTimestamps:
    append(r.output, "[")
    writeTs(r)
    append(r.output, "] ")

  appendLogLevelMarker(r, lvl)

  when r.colors == AnsiColors:
    append(r.output, static ansiStyleCode(styleBright))

  append(r.output, name & "\n")

  when r.colors == AnsiColors:
    append(r.output, ansiResetCode)

template setFirstProperty*(r: var TextBlockRecord, key: string, val: auto) =
  append(r.output, textBlockIndent)

  when r.colors == AnsiColors:
    append(r.output, ansiForegroundColorCode(fgBlue, false))

  append(r.output, key)
  append(r.output, ": ")

  when r.colors == AnsiColors:
    append(r.output, static ansiStyleCode(styleBright))

  append(r.output, $val)
  append(r.output, "\n")

  when r.colors == AnsiColors:
    append(r.output, ansiResetCode)

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

template initLogRecord*(r: var JsonRecord, lvl: LogLevel, name: string) =
  append(r.output, """{"msg": """ & jsonEncode(name) &
                   """, "lvl": """ & jsonEncode($lvl))

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

proc createCompositeLogRecord(sinks: seq[SinkSpec]): NimNode =
  if sinks.len > 1:
    result = newTree(nnkPar)
    for i in 0 ..< sinks.len:
      result.add selectRecordType(sinks[i])
  else:
    result = selectRecordType(sinks[0])

import dynamic_scope_types

template isStreamSymbolIMPL*(T: typed): bool = false

macro createStreamSymbol(name: untyped, recordType: typedesc): untyped =
  let tlsSlot = newIdentNode($name & "TlsSlot")

  result = quote:
    type `name`* {.inject.} = `recordType`

    template isStreamSymbolIMPL*(T: type `name`): bool = true

    var `tlsSlot` {.threadvar.}: ptr BindingsFrame[`recordType`]
    template tlsSlot*(T: type `recordType`): auto = `tlsSlot`

macro customLogStream*(streamDef: untyped): untyped =
  syntaxCheckStreamExpr streamDef
  return newCall(bindSym"createStreamSymbol", streamDef[0], streamDef[1])

macro logStream*(streamDef: untyped): untyped =
  syntaxCheckStreamExpr streamDef
  let streamSinks = sinkSpecsFromNode(streamDef)
  return newCall(bindSym"createStreamSymbol",
                 streamDef[0],
                 createCompositeLogRecord(streamSinks))

macro createStreamRecordTypes: untyped =
  result = newStmtList()

  for i in 0 ..< config.streams.len:
    let
      s = config.streams[i]
      streamName = newIdentNode(s.name)
      typeName = newIdentNode(s.name & "LogRecord")
      tlsSlot = newIdentNode($typeName & "TlsSlot")
      typeDef = createCompositeLogRecord(s.sinks)

    result.add quote do:
      type `typeName`* = `typeDef`

      when `typeName` is tuple:
        template initLogRecord*(r: var `typeName`, lvl: LogLevel, name: string) =
          for f in r.fields: initLogRecord(f, lvl, name)

        template setFirstProperty*(r: var `typeName`, key: string, val: auto) =
          for f in r.fields: setFirstProperty(f, key, val)

        template setProperty*(r: var `typeName`, key: string, val: auto) =
          for f in r.fields: setProperty(f, key, val)

        template flushRecord*(r: var `typeName`) =
          for f in r.fields: flushRecord(f)

      createStreamSymbol(`streamName`, `typeName`)

    if i == 0:
      result.add quote do:
        template activeChroniclesStream*: typedesc = `streamName`

createStreamRecordTypes()

#
# We open all file outputs at program start-up and close them automatically
# via a proc registered with `addQuitProc`. If some of the file outputs don't
# have assigned paths in the compile-time configuration, chronicles will
# automatically choose the log file names using the following rules:
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

import os

for stream in config.streams:
  var
    autoLogsPrefix = if stream.name != "default": stream.name
                    else: getAppFilename().splitFile.name
    autoLogsCount = 0

  for sink in stream.sinks:
    for dst in sink.destinations:
      if dst.kind == toFile:
        var filename = dst.filename
        if filename.len == 0:
          inc autoLogsCount
          filename = autoLogsPrefix
          if autoLogsCount > 1: filename.add("." & $autoLogsCount)
          filename.add ".log"

        createDir(filename.splitFile.dir)

        let openFlags = if dst.truncate: fmWrite else: fmAppend
        fileOutputs[dst.outputId] = open(filename, openFlags)

addQuitProc proc() {.noconv.} =
  for f in fileOutputs:
    if f != nil: close(f)

