import
  times, strutils, typetraits, terminal,
  serialization/object_serialization, faststreams/[outputs, textio],
  options, log_output, textformats

type
  LogRecord*[OutputKind;
             timestamps: static[TimestampScheme],
             colors: static[ColorScheme]] = object
    output*: OutputStream
    level: LogLevel
    when stackTracesEnabled:
      exception*: ref Exception

const
  # We work-around a Nim bug:
  # The compiler claims that the `terminal` module is unused
  styleBright = terminal.styleBright

proc appendValueImpl[T](r: var LogRecord, value: T) =
  mixin formatItIMPL

  when value is ref Exception:
    appendValueImpl(r, value.msg)
    when stackTracesEnabled:
      r.exception = value

  elif value is SomeNumber:
    appendText(r, value)

  elif value is enum:
    appendText(r, $value)

  elif value is object:
    appendChar(r, '{')
    var needsComma = false
    enumInstanceSerializedFields(value, fieldName, fieldValue):
      if needsComma: r.output.append ", "
      append(r.output, fieldName)
      append(r.output, ": ")
      appendValueImpl(r, formatItIMPL fieldValue)
      needsComma = true
    appendChar(r, '}')

  elif value is tuple:
    discard

  elif value is bool:
    append(r.output, if value: "true" else: "false")

  elif value is seq|array:
    appendChar(r, '[')
    for index, value in pairs(value):
      if index > 0: r.output.append ", "
      appendValueImpl(r, formatItIMPL value)
    appendChar(r, ']')

  elif value is string|cstring:
    let
      needsEscape = containsEscapedChars(value)
      needsQuote = needsEscape or needsQuotes(value)
    if needsQuote:
      appendChar(r, '"')
      if needsEscape:
        writeEscapedString(r.output, value)
      else:
        r.output.write value
      appendChar(r, '"')
    else:
      r.output.write value

  else:
    const typeName = typetraits.name(T)
    {.fatal: "The textlines format does not support the '" & typeName & "' type".}

template appendValue(r: var LogRecord, value: auto) =
  mixin formatItIMPL
  appendValueImpl(r, formatItIMPL value)

when false:
  proc quoteIfNeeded(r: var LogRecord, value: ref Exception) =
    r.stream.writeText value.name
    r.stream.writeText '('
    r.quoteIfNeeded value.msg
    when not defined(js) and not defined(nimscript) and hostOS != "standalone":
      r.stream.writeText ", "
      r.quoteIfNeeded getStackTrace(value).strip
    r.stream.writeText ')'

proc appendFieldName*(r: var LogRecord, name: string) =
  mixin append
  r.output.append " "
  when r.colors != NoColors:
    let (color, bright) = levelToStyle(r.level)
    setFgColor r, color, bright
  r.output.append name
  resetColors r
  r.output.append "="

const
  # no good way to tell how much padding is going to be needed so we
  # choose an arbitrary number and use that - should be fine even for
  # 80-char terminals
  msgWidth = 42
  spaces = repeat(' ', msgWidth)

proc initLogRecord*(r: var LogRecord,
                    level: LogLevel,
                    topics, msg: string) =
  r.level = level
  r.output = initOutputStream type(r)

  # Log level comes first - allows for easy regex match with ^
  appendLogLevelMarker(r, level)

  writeSpaceAndTs(r)

  let msgLen = msg.len
  r.output.append " "
  applyStyle(r, styleBright)
  if msgLen < msgWidth:
    r.output.append msg
    r.output.append spaces.toOpenArray(1, msgWidth - msgLen)
  else:
    r.output.append msg.toOpenArray(0, msgWidth - 3)
    r.output.append ".. "

  resetColors(r)

  if topics.len > 0:
    r.output.append " topics=\""
    setFgColor(r, topicsColor, true)
    r.output.append topics
    resetColors(r)
    r.output.append "\""

proc setProperty*(r: var LogRecord, name: string, value: auto) =
  r.appendFieldName name

  r.setFgColor propColor, true
  r.appendValue value
  r.resetColors

proc flushRecord*(r: var LogRecord) =
  r.output.append "\n"

  when stackTracesEnabled:
    if r.exception != nil:
      appendStackTrace(r)

  flushOutput r.OutputKind, r.output

