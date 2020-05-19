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
# value support functions
#

const
  escChars: set[char] = strutils.NewLines + {'"', '\\'}
  quoteChars: set[char] = {' ', '='}

type
  typesNotNeedingQuotes = float | float64 | float32 | uint8 | uint16 | uint32 | uint64 | int | int8 | int16 | int32 | int64

proc quoteIfNeeded(w: var TextLineWriter, val: typesNotNeedingQuotes) =
  w.stream.writeText val

proc quoteIfNeeded(w: var TextLineWriter, val: auto) =
  let valText = $val
  let
    needsEscape = valText.find(escChars) > -1
    needsQuote = (valText.find(quoteChars) > -1) or needsEscape
  if needsQuote:
    var quoted = ""
    quoted.addQuoted valText
    w.stream.writeText quoted
  else:
    w.stream.writeText val

proc quoteIfNeeded(w: var TextLineWriter, val: ref Exception) =
  w.stream.writeText val.name
  w.stream.writeText '('
  w.quoteIfNeeded val.msg
  when not defined(js) and not defined(nimscript) and hostOS != "standalone":
    w.stream.writeText ", "
    w.quoteIfNeeded getStackTrace(val).strip
  w.stream.writeText ')'

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
  w.setForegroundColor(color, bright)
  w.stream.writeText name
  w.resetAllColors()
  w.stream.writeText "="

proc writeValue*(w: var TextLineWriter, value: auto) =
  w.setForegroundColor(propColor, true)
  w.quoteIfNeeded(value)
  w.resetAllColors()

proc writeArray*[T](w: var TextLineWriter, elements: openarray[T]) =
  w.stream.writeText '['
  let clen = elements.len
  for index, value in elements.pairs:
    w.stream.writeText value
    if index < clen:
      w.stream.writeText ", "
  w.stream.writeText ']'

proc writeIterable*(w: var TextLineWriter, collection: auto) =
  w.stream.writeText '{'
  let clen = collection.len
  for index, value in collection.pairs:
    w.stream.writeText value
    if index < clen:
      w.stream.writeText ", "
  w.stream.writeText '}'

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
    if titleLen > 42:
      w.stream.writetext title
    else:
      for index in 0 ..< 42:
        if index < titleLen:
          w.stream.writeText title[index]
        else:
          w.stream.writeText ' '
    w.resetAllColors()
  if topics.len > 0:
    w.stream.writeText " topics=\""
    w.setForegroundColor(topicsColor, true)
    w.stream.writeText topics
    w.resetAllColors()
    w.stream.writeText '"'

proc endRecord*(w: var TextLineWriter) =
  w.stream.write '\n'
