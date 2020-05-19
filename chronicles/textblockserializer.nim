import
  times,
  strutils,
  terminal,
  system,
  options

import
  serialization,
  faststreams/[outputs, textio]

import
  chronicles,
  options

type
  TextBlockWriter*[timeFormat: static[TimestampsScheme], colorScheme: static[ColorScheme]] = object
    stream: OutputStream
    currentLevel: LogLevel

  TextBlockReader* = object
    lexer: string

serializationFormat TextBlockLog,
                    Reader = TextBlockReader,
                    Writer = TextBlockWriter,
                    PreferedOutput = string,
                    mimeType = "text/plain"

#
# Class startup
#

proc init*(w: var TextBlockWriter, stream: OutputStream) =
  w.stream = stream

#
# Field Handling
#

proc writeFieldName*(w: var TextBlockWriter, name: string) =
  w.stream.writeText name
  w.stream.writeText ": "

proc writeValue*(w: var TextBlockWriter, value: auto) =
  w.stream.writeText value

proc writeArray*[T](w: var TextBlockWriter, elements: openarray[T]) =
  w.stream.writeText '['
  let clen = elements.len
  for index, value in elements.pairs:
    w.stream.writeText value
    if index < clen:
      w.stream.writeText ", "
  w.stream.writeText ']'

proc writeIterable*(w: var TextBlockWriter, collection: auto) =
  w.stream.writeText '{'
  let clen = collection.len
  for index, value in collection.pairs:
    w.stream.writeText value
    if index < clen:
      w.stream.writeText ", "
  w.stream.writeText '}'

proc writeField*(w: var TextBlockWriter, name: string, value: auto) =
  w.stream.writeText textBlockIndent
  w.setForegroundColor(propColor, false)
  writeFieldName(w, name)
  w.applyColorStyle(styleBright)
  var first = true
  for part in ($value).splitLines:
    if not first:
      w.stream.writeText textBlockIndent & repeat(' ', name.len + 2)
    writeValue(w, part)
    w.stream.writeText "\n"
    first = false
  w.resetAllColors()

# template endRecordField*(w: var TextBlockWriter) =
#   discard

#
# Record Handling
#

proc beginRecord*(w: var TextBlockWriter, level: LogLevel, topics, title: string) =
  w.currentLevel = level
  let (logColor, logBright) = levelToStyle(level)
  w.setForegroundColor(logColor, logBright)
  w.stream.writeText shortName(w.currentLevel)
  w.resetAllColors()
  when w.timeFormat == UnixTime:
    w.stream.writeText ' '
    w.stream.writeText formatFloat(epochTime(), ffDecimal, 6)
  when w.timeFormat == RfcTime:
    w.stream.writeText now().format(" yyyy-MM-dd HH:mm:sszzz")
  let titleLen = title.len
  if titleLen > 0:
    w.stream.writeText ' '
    w.applyColorStyle(styleBright)
    w.stream.writetext title
    w.resetAllColors()
  if topics.len > 0:
    w.stream.writeText " topics=\""
    w.setForegroundColor(topicsColor, true)
    w.stream.writeText topics
    w.resetAllColors()
    w.stream.writeText '"'
  w.stream.writeText '\n'

proc endRecord*(w: var TextBlockWriter) =
  w.stream.writeText '\n'
