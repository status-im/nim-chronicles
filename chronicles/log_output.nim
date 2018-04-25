import
  times, strutils

const
  chronicles_timestamps {.strdefine.} = "on"
  chronicles_sinks {.strdefine.} = ""
  chronicles_indent {.intdefine.} = 2

  enableTimestamps = chronicles_timestamps.toLowerAscii == "on"
  indent = repeat(' ', chronicles_indent)

when chronicles_timestamps.toLowerAscii notin ["on", "off"]:
  {.error: "chronicles_timestamps must be set to either 'on' or 'off'".}

type
  FileOutput = object

  LogLevel* = enum
    ALL,
    DEBUG,
    INFO,
    NOTICE,
    WARN,
    ERROR,
    FATAL,
    NONE

  TextlineRecord[Output] = object
    output: Output

  TextblockRecord[Output] = object
    output: Output

  JsonRecord[Output] = object
    output: Output

var
  logOutput: File

when chronicles_sinks.len > 0:
  {.error: "X".}
else:
  type
    LogOutput* = TextblockRecord[FileOutput]

template append(o: var FileOutput, s: string) =
  logOutput.write s

template setStyle(o: var FileOutput, lvl: LogLevel) =
  append(o, "[")
  append(o, $lvl)
  append(o, "] ")

template resetStyle(o: var FileOutput) =
  discard

template flushOutput(o: var FileOutput) =
  logOutput.flushFile

template append(o: var string, s: string) =
  o.add(s)

template flushOutput(o: var string) =
  discard

template setStyle(o: var string, lvl: LogLevel) =
  append(o, "[")
  append(o, $lvl)
  append(o, "] ")

template resetStyle(o: var string) =
  discard

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

# Text line record

template setEventName*(r: var TextlineRecord, lvl: LogLevel, name: string) =
  when enableTimestamps:
    append(r.output, "[")
    appendTimestamp(r.output)
    append(r.output, "] ")
  setStyle(r.output, lvl)
  append(r.output, name & ":")

template setFirstProperty*(r: var TextlineRecord, key: string, val: auto) =
  append(r.output, " ")
  append(r.output, key)
  append(r.output, "=")
  append(r.output, $val)

template setProperty*(r: var TextlineRecord, key: string, val: auto) =
  append(r.output, ",")
  setFirstProperty(r, key, val)

template flushRecord*(r: var TextlineRecord) =
  append(r.output, "\n")
  flushOutput(r.output)
  resetStyle(r.output)

# Textblock records

template setEventName*(r: var TextblockRecord, lvl: LogLevel, name: string) =
  when enableTimestamps:
    append(r.output, "[")
    appendTimestamp(r.output)
    append(r.output, "] ")
  setStyle(r.output, lvl)
  append(r.output, name & "\n")
  resetStyle(r.output)

template setFirstProperty*(r: var TextblockRecord, key: string, val: auto) =
  append(r.output, indent)
  append(r.output, key)
  append(r.output, ": ")
  append(r.output, $val)
  append(r.output, "\n")

template setProperty*(r: var TextblockRecord, key: string, val: auto) =
  setFirstProperty(r, key, val)

template flushRecord*(r: var TextblockRecord) =
  append(r.output, "\n")
  flushOutput(r.output)

# JSON output

import json

template jsonEncode(x: auto): string = $(%x)

template setEventName*(r: var JsonRecord, lvl: LogLevel, name: string) =
  append(r.output, """{"msg": """ & name.jsonEncode &
                   """, "lvl": """ & ($lvl).jsonEncode)

  when enableTimestamps:
    var ts: string
    appendTimestamp(ts)
    append(r.output, ""","ts": """)
    append(r.output, ts.jsonEncode)

template setFirstProperty*(r: var JsonRecord, key: string, val: auto) =
  append(r.output, ", ")
  append(r.output, key.jsonEncode)
  append(r.output, ": ")
  append(r.output, val.jsonEncode)

template setProperty*(r: var JsonRecord, key: string, val: auto) =
  setFirstProperty(r, key, val)

template flushRecord*(r: var JsonRecord) =
  append(r.output, "}\n")
  flushOutput(r.output)

template optimizeLogWrites*{
  write(f, x)
  write(f, y)
}(x, y: string{lit}, f: File) =
  write(f, x & y)

logOutput = stdout

