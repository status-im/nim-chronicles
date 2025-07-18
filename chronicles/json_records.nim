import ./[log_output, options, timestamp]

when not defined(js):
  import faststreams/outputs, json_serialization/writer

  export outputs, writer, timestamp

  type LogRecord*[Output; format: static[FormatSpec]] = object
    output*: Output
    stream*: OutputStream
    jsonWriter: Json.Writer

  template setProperty*(r: var LogRecord, key: string, val: auto) =
    writeField(r.jsonWriter, key, val)

  template flushRecord*(r: var LogRecord) =
    r.jsonWriter.endRecord()
    r.stream.write '\n'
    append r.output, r.stream

else:
  import jscore, jsconsole, jsffi

  export convertToConsoleLoggable

  type JsonString* = distinct string

  type LogRecord*[
    Output; timestamps: static[TimestampScheme], colors: static[ColorScheme]
  ] = object
    output: Output
    record: js

  template setProperty*(r: var LogRecord, key: string, val: auto) =
    r.record[key] =
      when val is string:
        cstring(val)
      else:
        val

  proc flushRecord*(r: var LogRecord) =
    append r.output, JSON.stringify(r.record)
    flushOutput r.output

proc initLogRecord*(r: var LogRecord, level: LogLevel, topics, msg: string) =
  r.stream = initOutputStream type(r)

  when defined(js):
    r.record = newJsObject()
  else:
    r.jsonWriter = Json.Writer.init(r.stream, pretty = false)
    r.jsonWriter.beginRecord()

  if level != LogLevel.NONE:
    setProperty(r, "lvl", level.shortName)

  when r.format.timestamps != TimestampScheme.NoTimestamps:
    when not defined(js):
      r.jsonWriter.writeFieldName("ts")

      when declared(streamElement):
        r.streamElement(s):
          s.writeTimestamp(r.format.timestamps)
      else:
        r.jsonWriter.stream.writeTimestamp(r.format.timestamps)
        r.jsonWriter.fieldWritten()
    else:
      setProperty(r, "ts", r.timestamp())

  setProperty(r, "msg", msg)

  if topics.len > 0:
    setProperty(r, "topics", topics)
