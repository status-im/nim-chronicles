## A log format inspired by https://brandur.org/logfmt#human

import
  std/[strutils, typetraits, terminal],
  serialization/object_serialization,
  faststreams/[outputs, textio],
  ./[formats, options, log_output, textformats]

export outputs, textio, formats, textformats

type LogRecord*[Output; format: static[FormatSpec]] = object of TextLogRecord[
  Output, format
]
  level: LogLevel

const
  styleBright = terminal.styleBright # avoid terminal being unused in nocolors
  controlChars = {'\x00' .. '\x1f'}
  extendedAsciiChars = {'\x7f' .. '\xff'}
  escapedChars: set[char] = {'\n', '\r', '"', '\\'} + controlChars + extendedAsciiChars
  quoteChars: set[char] = {' ', '='}

# Nim 2.0 compat
template base(r: var LogRecord): untyped = TextLogRecord[r.Output, r.format](r)

func containsEscapedChars(str: string | cstring): bool =
  for c in str:
    if c in escapedChars:
      return true
  return false

func needsQuotes(str: string | cstring): bool =
  for c in str:
    if c in quoteChars:
      return true
  return false

proc writeValueImpl[T](
    r: var LogRecord, value: T, deref: static bool, quoted: static bool
) =
  mixin chroniclesFormatItIMPL

  template maybeQuote(body) {.used.} =
    when not quoted:
      r.stream.write('"')
    body
    when not quoted:
      r.stream.write('"')

  when value is ref Exception:
    r.writeValueImpl(value.msg, deref = false, quoted = quoted)
  elif value is ref:
    if value.isNil:
      r.stream.write("nil")
    else:
      when deref:
        r.writeValueImpl(chroniclesFormatItIMPL value[], deref = false, quoted = quoted)
      else:
        # Avoid infinite recursion and other evils
        r.stream.write("...")
  elif value is enum:
    r.stream.write($value)
  elif value is array | seq | openArray:
    if value.len == 0:
      r.stream.write("[]") # No quotes needed
    else:
      maybeQuote:
        r.stream.write('[')
        var next: bool
        for v in items(value):
          if next:
            r.stream.write(", ")
          else:
            next = true

          r.writeValueImpl(chroniclesFormatItIMPL v, deref = v is ref, quoted = quoted)
        r.stream.write(']')
  elif value is (object | tuple) and isDefaultDollar($value):
    # Only used if there is no specialized `$` for the type
    maybeQuote:
      r.stream.write('(')
      var next: bool
      enumInstanceSerializedFields(value, fieldName, v):
        if next:
          r.stream.write(", ")
        else:
          next = true

        when value is object or isNamedTuple(typeof(value)):
          r.stream.write(fieldName)
          r.stream.write(": ")
        else:
          discard fieldName
        r.writeValueImpl(chroniclesFormatItIMPL v, deref = false, quoted = true)
      r.stream.write(')')
  elif value is string | cstring:
    # Escaping is done to avoid issues with quoting and newlines
    # Quoting is done to distinguish strings with spaces in them from a new
    # key-value pair
    # https://github.com/csquared/node-logfmt/blob/master/lib/stringify.js#L13
    let
      needsEscape = quoted or containsEscapedChars(value)
      needsQuote = not quoted and (needsEscape or needsQuotes(value))
    if needsQuote:
      r.stream.write('"')
    if needsEscape:
      r.stream.writeEscapedString(value)
    else:
      r.stream.write(value)
    if needsQuote:
      r.stream.write('"')
  elif compiles(r.stream.writeText(value)):
    r.stream.writeText(value)
  elif compiles($value):
    r.writeValueImpl($value, deref = false, quoted)
  else:
    const typeName = typetraits.name(T)
    {.fatal: "The textlines format does not support the '" & typeName & "' type".}

template writeValue(r: var LogRecord, value: auto) =
  mixin chroniclesFormatItIMPL
  r.writeValueImpl(chroniclesFormatItIMPL value, deref = value is ref, quoted = false)

proc writeFieldName(r: var LogRecord, name: string) =
  r.stream.write(' ')
  when r.format.colors != NoColors:
    let (color, bright) = levelToStyle(r.level)
    base(r).setFgColor(color, bright)
  r.stream.write name
  base(r).resetColors()
  r.stream.write('=')

const
  # no good way to tell how much padding is going to be needed so we
  # choose an arbitrary number and use that - should be fine even for
  # 80-char terminals
  msgWidth = 42
  spaces = repeat(' ', msgWidth)

proc initLogRecord*(r: var LogRecord, level: LogLevel, topics, msg: string) =
  r.stream = initOutputStream type(r)
  r.level = level

  # Log level comes first - allows for easy regex match with ^
  base(r).writeLogLevelMarker(level)
  base(r).writeSpaceAndTs()

  r.stream.write(' ')
  base(r).applyStyle(styleBright)
  r.stream.write(msg)

  if msg.len < msgWidth:
    r.stream.write(spaces.toOpenArray(1, msgWidth - msg.len))

  base(r).resetColors()

  if topics.len > 0:
    r.writeFieldName("topics")
    base(r).setFgColor(topicsColor, true)
    r.stream.write('"')
    r.stream.write(topics)
    r.stream.write('"')
    base(r).resetColors()

proc setProperty*(r: var LogRecord, name: string, value: auto) =
  r.writeFieldName(name)

  base(r).setFgColor(propColor, true)
  r.writeValue(value)
  base(r).resetColors()

proc flushRecord*(r: var LogRecord) =
  r.stream.write(newLine)

  r.output.append(r.stream)
  r.output.flushOutput()
