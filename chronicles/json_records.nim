import
  options, log_output

when not defined(js):
  import
    faststreams/outputs,
    json_serialization

  export
    outputs, json_serialization

  type
    LogRecord*[OutputKind;
               timestamps: static[TimestampScheme],
               colors: static[ColorScheme]] = object
      output*: OutputStream
      jsonWriter: JsonWriter

  template setProperty*(r: var LogRecord, key: string, val: auto) =
    writeField(r.jsonWriter, key, val)

  template flushRecord*(r: var LogRecord) =
    r.jsonWriter.endRecord()
    r.output.write '\n'
    flushOutput r.OutputKind, r.output

else:
  import
    jscore, jsconsole, jsffi

  export
    convertToConsoleLoggable

  type
    JsonString* = distinct string

  type
    LogRecord*[OutputKind;
               timestamps: static[TimestampScheme],
               colors: static[ColorScheme]] = object
      output*: Output
      record: js

  template setProperty*(r: var LogRecord, key: string, val: auto) =
    r.record[key] = when val is string: cstring(val) else: val

  proc flushRecord*(r: var LogRecord) =
    r.output.append JSON.stringify(r.record)
    flushOutput r.OutputKind, r.output

import typetraits

template initOutputStream(x: auto): auto =
  static: echo type(x).name
  memoryOutput()

proc initLogRecord*(r: var LogRecord,
                    level: LogLevel,
                    topics: string,
                    msg: string) =
  r.output = initOutputStream type(r)

  when defined(js):
    r.record = newJsObject()
  else:
    r.jsonWriter = JsonWriter.init(r.output, pretty = false)
    r.jsonWriter.beginRecord()

  if level != NONE:
    setProperty(r, "lvl", level.shortName)

  when r.timestamps != NoTimestamps:
    when not defined(js):
      r.jsonWriter.writeFieldName("ts")
      when r.timestamps == RfcTime: r.output.write '"'
      r.writeTs()
      when r.timestamps == RfcTime: r.output.write '"'
      r.jsonWriter.fieldWritten()
    else:
      setProperty(r, "ts", r.timestamp())

  setProperty(r, "msg", msg)

  if topics.len > 0:
    setProperty(r, "topics", topics)

template setFirstProperty*(r: LogRecord, key: string, val: auto) =
  setProperty(r, key, val)

