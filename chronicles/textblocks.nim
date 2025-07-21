## Multi-line log format with indentation, similar to yaml
import
  std/[strutils, terminal, typetraits],
  serialization/object_serialization,
  faststreams/[outputs, textio],
  ./[formats, log_output, options, textformats]

export outputs, formats, textformats

type LogRecord*[Output; format: static[FormatSpec]] = object of TextLogRecord[
  Output, format
]
  level: LogLevel

const
  tupleOpenBracket = "(" & newLine
  tupleCloseBracket = ")" & newLine
  arrayOpenBracket = "[" & newLine
  arrayCloseBracket = "]" & newLine
  styleBright = terminal.styleBright # avoid terminal being unused in nocolors

# Nim 2.0 compat
template base(r: var LogRecord): untyped = TextLogRecord[r.Output, r.format](r)

proc writeIndent(stream: OutputStream, depthLevel, extra: int) =
  for i in 0 ..< depthLevel:
    stream.write(indentStr)
  for i in 0 ..< extra:
    stream.write(" ")

proc writeFieldName(r: var LogRecord, name: string) =
  when r.format.colors != NoColors:
    let (color, bright) = levelToStyle(r.level)
    base(r).setFgColor(color, bright)
  r.stream.write name
  base(r).resetColors()
  r.stream.write ": "

template writeStyledValue(r: var LogRecord, body: untyped) =
  base(r).setFgColor(propColor, true)
  body
  base(r).resetColors()

proc writeValueImpl[T](
    r: var LogRecord, value: T, depthLevel, extraIndent: int, deref: static bool
) =
  mixin chroniclesFormatItIMPL

  when value is ref Exception:
    r.writeValueImpl(value.msg, depthLevel, extraIndent, deref = false)
  elif value is ref:
    if value.isNil:
      r.writeStyledValue:
        r.stream.write("nil")
      r.stream.write(newLine)
    else:
      when deref:
        r.writeValueImpl(
          chroniclesFormatItIMPL value[], depthLevel, extraIndent, deref = false
        )
      else:
        # Avoid infinite recursion and other evils
        r.writeStyledValue:
          r.stream.write("...")
        r.stream.write(newLine)
  elif value is enum:
    r.writeStyledValue:
      r.stream.write($value)
    r.stream.write(newLine)
  elif value is array | seq | openArray:
    r.stream.write(arrayOpenBracket)
    for value in items(value):
      r.stream.writeIndent(depthLevel + 1, extraIndent)
      r.writeValueImpl(
        chroniclesFormatItIMPL(value), depthLevel + 1, extraIndent, deref = value is ref
      )
    r.stream.writeIndent(depthLevel, extraIndent)
    r.stream.write arrayCloseBracket
  elif value is object and isDefaultDollar($value):
    r.stream.write(newLine)
    enumInstanceSerializedFields(value, fieldName, fieldValue):
      r.stream.writeIndent(depthLevel + 1, extraIndent)
      r.writeFieldName(fieldName)
      r.writeValueImpl(
        chroniclesFormatItIMPL(fieldValue),
        depthLevel + 1,
        extraIndent + fieldName.len + 2,
        deref = false,
      )
  elif value is tuple and isDefaultDollar($value):
    r.stream.write(tupleOpenBracket)
    for name, v in fields(value):
      r.stream.writeIndent(depthLevel + 1)
      let extraIndent =
        extraIndent + (
          when isNameTuple(typeof(v)):
            r.writeFieldName(name)
            name.len + 2
          else:
            discard name
            0
        )
      r.writeValueImpl(
        chroniclesFormatItIMPL(v), depthLevel + 1, extraIndent, deref = false
      )
    r.stream.writeIndent(depthLevel, extraIndent)
    r.stream.write tupleCloseBracket
  elif value is string | cstring:
    r.writeStyledValue:
      var first = true
      for line in splitLines(value):
        if not first:
          r.stream.writeIndent(depthLevel, extraIndent)
        r.stream.writeEscapedString(line)
        r.stream.write(newLine)
        first = false
  elif compiles(r.stream.writeText(value)):
    r.writeStyledValue:
      r.stream.writeText(value)
    r.stream.write(newLine)
  elif compiles($value):
    r.writeValueImpl($value, deref = false)
  else:
    const typeName = typetraits.name(T)
    {.fatal: "The textblocks format does not support the '" & typeName & "' type".}

template writeValue(r: var LogRecord, value: auto, depthLevel, extraIndent: int) =
  mixin chroniclesFormatItIMPL
  r.writeValueImpl(
    chroniclesFormatItIMPL value, depthLevel, extraIndent, deref = value is ref
  )

proc setProperty*(r: var LogRecord, name: string, value: auto) =
  r.stream.writeIndent(1, 0)
  r.writeFieldName(name)
  r.writeValue(value, 1, len(name) + 2)

proc initLogRecord*(r: var LogRecord, level: LogLevel, topics, msg: string) =
  r.stream = initOutputStream type(r)
  r.level = level

  base(r).writeLogLevelMarker(level)
  base(r).writeSpaceAndTs()

  r.stream.write(' ')
  base(r).applyStyle(styleBright)
  r.stream.write(msg)
  base(r).resetColors()

  if topics.len > 0:
    r.stream.write(' ')
    base(r).setFgColor(propColor, false)
    r.stream.write("topics")
    base(r).resetColors()

    r.stream.write('=')
    base(r).setFgColor(topicsColor, true)
    r.stream.write('"')
    r.stream.write(topics)
    r.stream.write('"')

  r.stream.write(newLine)

proc flushRecord*(r: var LogRecord) =
  r.stream.write(newLine)

  r.output.append(r.stream)
  r.output.flushOutput()
