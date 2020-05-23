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
  TextBlockWriter*[timestamps: static[TimestampsScheme], colors: static[ColorScheme]] = ref object of WriterType[timestamps, colors]
    stream: OutputStream
    currentLevel: LogLevel

  TextBlockReader* = object
    lexer: string

serializationFormat TextBlock,
                    Reader = TextBlockReader,
                    Writer = TextBlockWriter,
                    PreferedOutput = string,
                    mimeType = "text/plain"

#
# Class startup
#

# proc init*(w: var TextBlockWriter, stream: OutputStream) =
#   w.stream = stream

proc init*(T: type TextBlockWriter, stream: OutputStream): T =
  result.stream = stream


#
# Field Handling
#

proc writeValue*(w: var TextBlockWriter, value: auto, prefix = 0) # forward ref

proc writeFieldName*(w: var TextBlockWriter, name: string) =
  setForegroundColor(w, propColor, false)
  w.stream.writeText name
  w.stream.writeText ": "
  resetAllColors(w)

proc writeArray*[T](w: var TextBlockWriter, elements: openarray[T]) =
  w.stream.writeText '['
  let clen = elements.len - 1
  for index, value in elements.pairs:
    w.stream.writeText value
    if index < clen:
      w.stream.writeText ", "
  w.stream.writeText ']'

proc writeIterable*(w: var TextBlockWriter, collection: auto) =
  w.stream.writeText '['
  let clen = collection.len - 1
  for index, value in collection.pairs:
    w.stream.writeText value
    if index < clen:
      w.stream.writeText ", "
  w.stream.writeText ']'

proc writeField*(w: var TextBlockWriter, name: string, value: auto, prefix = 0) =
  w.stream.writeText textBlockIndent & repeat(' ', prefix)
  writeFieldName(w, name)
  writeValue(w, value, prefix=name.len + 2)

type
  SomeTime = Time | DateTime | times.Duration | TimeInterval | Timezone | ZonedTime

proc writeValue*(w: var TextBlockWriter, value: auto, prefix = 0) =
  setForegroundColor(w, propColor, false)
  applyColorStyle(w, styleBright)
  when value is array or value is seq:
    writeIterable(w, value)
    w.stream.writeText "\n"
  elif value is SomeTime | SomeNumber | bool: # all types that sit on a single line
    w.stream.writeText value
    w.stream.writeText "\n"
  elif value is object:
    w.stream.write $type(value)
    w.stream.write "{\n"
    resetAllColors(w)
    enumInstanceSerializedFields(value, fieldName, fieldValue):
      writeField(w, fieldName, fieldValue, prefix=prefix + textBlockIndent.len)
    w.stream.writeText textBlockIndent & repeat(' ', prefix)
    setForegroundColor(w, propColor, false)
    applyColorStyle(w, styleBright)
    w.stream.write "}\n"
  else:
    var first = true
    for part in ($value).splitLines:
      if not first:
        w.stream.writeText textBlockIndent & repeat(' ', prefix)
      w.stream.writeText part
      w.stream.writeText "\n"
      first = false
  resetAllColors(w)

# template endRecordField*(w: var TextBlockWriter) =
#   discard

#
# Record Handling
#

proc beginRecord*(w: var TextBlockWriter, level: LogLevel, topics, title: string) =
  w.currentLevel = level
  let (logColor, logBright) = levelToStyle(level)
  setForegroundColor(w, logColor, logBright)
  w.stream.writeText shortName(w.currentLevel)
  resetAllColors(w)
  when w.timeFormat == UnixTime:
    w.stream.writeText ' '
    w.stream.writeText formatFloat(epochTime(), ffDecimal, 6)
  when w.timeFormat == RfcTime:
    w.stream.writeText now().format(" yyyy-MM-dd HH:mm:sszzz")
  let titleLen = title.len
  if titleLen > 0:
    w.stream.writeText ' '
    applyColorStyle(w, styleBright)
    w.stream.writetext title
    resetAllColors(w)
  if topics.len > 0:
    w.stream.writeText " topics=\""
    setForegroundColor(w, topicsColor, true)
    w.stream.writeText topics
    resetAllColors(w)
    w.stream.writeText '"'
  w.stream.writeText '\n'

proc endRecord*(w: var TextBlockWriter) =
  w.stream.writeText '\n'
