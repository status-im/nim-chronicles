import
  times,
  strutils,
  terminal

import
  serialization,
  faststreams/[outputs, textio]

import
  chronicles,
  options

type
  TextLineWriter*[timeFormat: static[TimestampsScheme], colorScheme: static[ColorScheme]] = object
    stream: OutputStream
    currentLevel: LogLevel

  TextLineReader* = object
    lexer: string

serializationFormat TextLineLog,
                    Reader = TextLineReader,
                    Writer = TextLineWriter,
                    PreferedOutput = string,
                    mimeType = "text/plain"

#
# color support functions
#
proc fgColor(writer: TextLineWriter, color: ForegroundColor, brightness: bool) =
  when writer.colorScheme == AnsiColors:
    writer.stream.writeText ansiForegroundColorCode(color, brightness)
  when writer.colorScheme == NativeColors:
    writer.stream.setForegroundColor(color, brightness)

proc resetColors(writer: TextLineWriter) =
  when writer.colorScheme == AnsiColors:
    writer.stream.writeText ansiResetCode
  when writer.colorScheme == NativeColors:
    writer.stream.resetAttributes()

proc applyStyle(writer: TextLineWriter, style: Style) =
  when writer.colorScheme == AnsiColors:
    writer.stream.writeText ansiStyleCode(style)
  when writer.colorScheme == NativeColors:
    writer.stream.setStyle({style})

#
# Class startup
#
proc init*(w: var TextLineWriter, stream: OutputStream) =
  w.stream = stream

#
# Field Handling
#
proc writeFieldName*(w: var TextLineWriter, name: string) =
  w.stream.writeText ' '
  let (color, bright) = levelToStyle(w.currentLevel)
  w.fgColor(color, bright)
  w.stream.writeText name
  w.resetColors()
  w.stream.writeText "="

proc writeValue*(w: var TextLineWriter, value: auto) =
  w.fgColor(propColor, true)
  w.stream.writeTextQuoted(value, optional=true)
  w.resetColors()

proc writeArray*[T](w: var TextLineWriter, elements: openarray[T]) =
  w.stream.writeText '['
  let clen = elements.len
  for index, value in elements.pairs:
    w.stream.writeText value
    if index < clen:
      w.stream.writeText ", "
  w.stream.writeText ']'

# TODO: is this meant to be for key/value lists?
proc writeIterable*(w: var TextLineWriter, collection: auto) =
  w.stream.writeText '['
  let clen = collection.len
  for index, value in collection.pairs:
    w.stream.writeText value
    if index < clen:
      w.stream.writeText ", "
  w.stream.writeText ']'

proc writeField*(w: var TextLineWriter, name: string, value: auto) =
  writeFieldName(w, name)
  writeValue(w, value)

# template endRecordField*(w: var TextLineWriter) =
#   discard

#
# Record Handling
#
proc beginRecord*(w: var TextLineWriter, level: LogLevel, topics, title: string) =
  w.currentLevel = level
  let (logColor, logBright) = levelToStyle(level)
  w.fgColor(logColor, logBright)
  w.stream.writeText shortName(w.currentLevel)
  w.resetColors()
  when w.timeFormat == UnixTime:
    w.stream.writeText ' '
    w.stream.writeText formatFloat(epochTime(), ffDecimal, 6)
  when w.timeFormat == RfcTime:
    w.stream.writeText now().format(" yyyy-MM-dd HH:mm:sszzz")
  let titleLen = title.len
  if titleLen > 0:
    w.stream.writeText ' '
    w.applyStyle(styleBright)
    if titleLen > 42:
      w.stream.writetext title
    else:
      for index in 0 ..< 42:
        if index < titleLen:
          w.stream.writeText title[index]
        else:
          w.stream.writeText ' '
    w.resetColors()
  if topics.len > 0:
    w.stream.writeText " topics=\""
    w.fgColor(topicsColor, true)
    w.stream.writeText topics
    w.resetColors()
    w.stream.writeText '"'

proc endRecord*(w: var TextLineWriter) =
  w.stream.write '\n'
