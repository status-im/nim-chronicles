import
  times, strutils, macros, options, terminal

export
  LogLevel

type
  FileOutput[sinkIndex: static[int]] = object
  StdOutOutput = object
  StdErrOutput = object
  SysLogOutput = object

  BufferedOutput[FinalOutputs: tuple] = object
    buffer: string

  TextLineRecord[Output; colors: static[ColorScheme]] = object
    output: Output

  TextBlockRecord[Output; colors: static[ColorScheme]] = object
    output: Output

  JsonRecord[Output] = object
    output: Output

# XXX: `bindSym` is currently broken and doesn't return proper type symbols
# (the resulting nodes should have a `tyTypeDesc` type, but they don't)
# Until this is fixed, use regular ident nodes to work-around the problem.
template bnd(s): NimNode =
  # bindSym(s)
  newIdentNode(s)

proc selectOutputType(sinkIdx: int, dst: LogDestination): NimNode =
  case dst.kind
  of toStdOut: bnd"StdOutOutput"
  of toStdErr: bnd"StdErrOutput"
  of toSysLog: bnd"SysLogOutput"
  of toFile:   newTree(nnkBracketExpr, bnd"FileOutput", newLit(sinkIdx))

proc selectRecordType(sinkIdx: int): NimNode =
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

  let sink = enabledSinks[sinkIdx]

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
      outputsTuple.add selectOutputType(sinkIdx, dst)

    bufferredOutput.add outputsTuple
    result.add bufferredOutput
  else:
    result.add selectOutputType(sinkIdx, sink.destinations[0])

  # Set the color scheme for the record types that require it
  if sink.format != json:
    result.add newIdentNode($sink.colorScheme)

var
  fileOutputs: array[enabledSinks.len, File]

# The `append` and `flushOutput` functions implement the actual writing
# to the log destinations (which we call Outputs).
# The LogRecord types are parametric on their Output and this is how we
# can support arbitrary combinations of log formats and destinations.

template append(o: var FileOutput, s: string) = fileOutputs[o.sinkIndex].write s
template flushOutput(o: var FileOutput)       = fileOutputs[o.sinkIndex].flushFile

template append(o: var StdOutOutput, s: string) = stdout.write s
template flushOutput(o: var StdOutOutput)       = stdout.flushFile

template append(o: var StdErrOutput, s: string) = stderr.write s
template flushOutput(o: var StdOutOutput)       = stdout.flushFile

# The buffered Output works in a very simple way. The log message is first
# buffered into a sting and when it needs to be flushed, we just instantiate
# each of the Output types and call `append` and `flush` on the instance:

template append(o: var BufferedOutput, s: string) =
  o.buffer.add(s)

template flushOutput(o: var BufferedOutput) =
  var finalOuputs: o.FinalOutputs
  for finalOutput in finalOuputs.fields:
    append(finalOutput, o.buffer)
    flushOutput(finalOutput)

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

proc appendTimestamp(o: var auto) =
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

template appendLogLevelMarker(r: var auto, lvl: LogLevel) =
  append(r.output, "[")

  when r.colors == AnsiColors:
    let (color, bright) = case lvl
                          of DEBUG: (fgGreen, false)
                          of INFO:  (fgGreen, true)
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
  when timestampsEnabled:
    append(r.output, "[")
    appendTimestamp(r.output)
    append(r.output, "] ")

  appendLogLevelMarker(r, lvl)
  when r.colors == AnsiColors: append(r.output, ansiStyleCode(styleBright))
  append(r.output, name)
  when r.colors == AnsiColors: append(r.output, ansiResetCode)

template setPropertyImpl(r: var TextLineRecord, key: string, val: auto) =
  when r.colors == AnsiColors:
    append(r.output, ansiForegroundColorCode(fgBlue))

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
  when timestampsEnabled:
    append(r.output, "[")
    appendTimestamp(r.output)
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
    append(r.output, ansiForegroundColorCode(fgBlue))

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

  when timestampsEnabled:
    append(r.output, """, "ts": """")
    appendTimestamp(r.output)
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
# When multiple sinks are present, we want to be able to create a tuple
# of the record types which can be passed by reference to the dynamically
# registered `appender` procs associated with the created dynamic bindings
# (see dynamic_scope.nim for more details).
#
# All operations on such "composite" records are just dispatched to the
# individual concrete record types stored inside the tuple.
#

macro createCompositeLogRecord(): untyped =
  if enabledSinks.len > 1:
    result = newTree(nnkPar)
    for i in 0 ..< enabledSinks.len:
      result.add selectRecordType(i)
  else:
    result = selectRecordType(0)

type CompositeLogRecord* = createCompositeLogRecord()

when CompositeLogRecord is tuple:
  template initLogRecord*(r: var CompositeLogRecord, lvl: LogLevel, name: string) =
    for f in r.fields: initLogRecord(f, lvl, name)

  template setFirstProperty*(r: var CompositeLogRecord, key: string, val: auto) =
    for f in r.fields: setFirstProperty(f, key, val)

  template setProperty*(r: var CompositeLogRecord, key: string, val: auto) =
    for f in r.fields: setProperty(f, key, val)

  template flushRecord*(r: var CompositeLogRecord) =
    for f in r.fields: flushRecord(f)

# Open all
import os

var
  appLogsCount = 0

for i in 0 ..< enabledSinks.len:
  let sink = enabledSinks[i]
  for dst in sink.destinations:
    if dst.kind == toFile:
      var filename = dst.filename
      if filename.len == 0:
        inc appLogsCount
        filename = getAppFilename().splitFile.name
        if appLogsCount > 1: filename.add("." & $appLogsCount)
        filename.add ".log"

      createDir(filename.splitFile.dir)
      fileOutputs[i] = open(filename, fmWrite)

addQuitProc proc() {.noconv.} =
  for f in fileOutputs:
    if f != nil: close(f)

