import
  times

import
  faststreams/[outputs, textio],
  json_serialization/writer

import
  options

# TODO: get json_serialization to support Time, ZonedTime, DateTime, etc.

# Note, cannot inherit from 'JsonWriter' directly because it is not an 'object of RootObj'
# So, we are doing it the hard way with a 'jwriter' field that is an instance of JsonWriter
# type
#   CJsonWriter*[timeFormat: static[TimestampsScheme], colorScheme: static[ColorScheme]] = object of JsonWriter

type
  CJsonWriter*[timeFormat: static[TimestampsScheme], colorScheme: static[ColorScheme]] = object
    jwriter: JsonWriter

proc init*(w: var CJsonWriter, stream: OutputStream) =
  w.jwriter = JsonWriter.init(stream, pretty = false)

proc writeFieldName*(w: var CJsonWriter, name: string) =
  writeFieldName(w.jwriter, name)

proc writeValue*(w: var CJsonWriter, value: auto) =
  writeValue(w.jwriter, value)

proc writeArray*[T](w: var CJsonWriter, elements: openarray[T]) =
  writeArray(w.jwriter, elements)

proc writeIterable*(w: var CJsonWriter, collection: auto) =
  writeIterable(w.jwriter, collection)

proc writeField*(w: var CJsonWriter, name: string, value: auto) =
  writeField(w.jwriter, name, value)

proc beginRecord*(w: var CJsonWriter, level: LogLevel, topics, title: string) =
  w.jwriter.beginRecord()
  if level != llNONE:
    w.jwriter.writeField("lvl", level.shortName())
  when w.timeFormat == UnixTime:
    w.jwriter.writeField("ts", formatFloat(epochTime(), ffDecimal, 6))
  elif w.timeFormat == RfcTime:
    w.jwriter.writeField("ts", now().format("yyyy-MM-dd HH:mm:sszzz"))
  w.jwriter.writeField("msg", title)
  if topics.len > 0:
    w.jwriter.writeField("topics", topics)

proc endRecord*(w: var CJsonWriter) =
  w.jwriter.endRecord()

proc getStream*(w: var CJsonWriter): OutputStream =
  result = w.jwriter.stream
