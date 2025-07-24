import ./[log_output, options, timestamp]

when not defined(js):
  import faststreams/outputs, json_serialization/writer

  export outputs, writer

  type LogRecord*[Output; format: static[FormatSpec]] = object
    output*: Output
    stream*: OutputStream
    jsonWriter: Json.Writer

  template setProperty*(r: var LogRecord, key: string, val: auto) =
    writeField(r.jsonWriter, key, val)

  template flushRecord*(r: var LogRecord) =
    r.jsonWriter.endRecord()
    r.stream.write(newLine)
    r.output.append(r.stream)
    r.output.flushOutput()

else:
  import jscore, jsconsole, jsffi

  type JsonString* = distinct string

  type LogRecord*[Output; format: static[FormatSpec]] = object
    output*: Output
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
  when defined(js):
    r.record = newJsObject()
  else:
    r.stream = initOutputStream type(r)
    r.jsonWriter = Json.Writer.init(r.stream, pretty = false)
    r.jsonWriter.beginRecord()

  if level != LogLevel.NONE:
    setProperty(r, "lvl", level.shortName)

  when r.format.timestamps != TimestampScheme.NoTimestamps:
    when not defined(js):
      r.jsonWriter.writeFieldName("ts")

      when declared(writer.streamElement): # json_serialization 0.3.0+
        r.jsonWriter.streamElement(s):
          s.writeTimestamp(r.format.timestamps)
      else:
        r.jsonWriter.stream.writeTimestamp(r.format.timestamps)
        r.jsonWriter.fieldWritten()
    else:
      setProperty(r, "ts", timestamp(r.format.timestamps))

  setProperty(r, "msg", msg)

  if topics.len > 0:
    setProperty(r, "topics", topics)
