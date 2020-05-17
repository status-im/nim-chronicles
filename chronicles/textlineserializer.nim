import chronicles
import times
import serialization
import faststreams/[outputs, textio]

type
  TextLineWriter* = object
    stream: OutputStream

  TextLineReader* = object
    lexer: string

serializationFormat TextLineLog,
                    Reader = TextLineReader,
                    Writer = TextLineWriter,
                    PreferedOutput = string,
                    mimeType = "text/plain"

#
# Class creation
#
proc init*(T: type TextLineWriter, stream: OutputStream): T =
  result.stream = stream

#
# Field Handling
#

proc writeFieldName*(w: var TextLineWriter, name: string) =
  w.stream.writeText ' '
  w.stream.writeText name
  w.stream.writeText "="

proc writeValue*(w: var TextLineWriter, value: auto) =
  w.stream.writeText value

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
proc beginRecord*(w: var TextLineWriter, level, topics, title: string) =
  w.stream.write level
  w.stream.write now().format(" yyyy-MM-dd HH:mm:sszzz ")
  let titleLen = title.len
  for index in 0 ..< 42:
    if index < titleLen:
      w.stream.write title[index]
    else:
      w.stream.write ' '

# proc beginRecord*(w: var TextLineWriter, T: type) =
#   discard

proc endRecord*(w: var TextLineWriter) =
  w.stream.write '\n'
