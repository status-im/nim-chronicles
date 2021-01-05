import
  times, strutils, terminal, typetraits,
  serialization, faststreams/[outputs, textio],
  log_output, textformats, options

type
  LogRecord*[OutputKind;
             timestamps: static[TimestampScheme],
             colors: static[ColorScheme]] = object
    output*: OutputStream
    when stackTracesEnabled:
      exception*: ref Exception

type
  SomeTime = Time | DateTime | times.Duration | TimeInterval | Timezone | ZonedTime

const
  arrayOpenBracket = "[" & newLine
  arrayCloseBracket = "]" & newLine

const
  # We work-around a Nim bug:
  # The compiler claims that the `terminal` module is unused
  styleBright = terminal.styleBright

proc appendIndent(output: var auto, depthLevel: int) =
  for i in 0 .. depthLevel:
    append(output, indentStr)

proc appendFieldName(r: var LogRecord, name: string, depthLevel: int) =
  appendIndent(r.output, depthLevel)
  r.setFgColor propColor, false
  r.output.append name
  r.output.append ": "
  r.resetColors()

proc appendValueImpl[T](r: var LogRecord, value: T, depthLevel: int) =
  mixin formatItIMPL

  setFgColor(r, propColor, false)
  applyStyle(r, styleBright)

  when value is ref Exception:
    appendValueImpl(r, value.msg, depthLevel)
    when stackTracesEnabled:
      r.exception = value

  elif value is array|seq:
    append(r.output, arrayOpenBracket)
    for value in items(collection):
      appendIndent(r.output, depthLevel + 1)
      appendValueImpl(r, formatItIMPL(value), depthLevel + 1)
    appendIndent(r.output, depthLevel)
    append(r.output, arrayCloseBracket)

  elif value is bool:
    append(r.output, if value: "true" else: "false")
    append(r.output, newLine)

  elif value is SomeTime | SomeNumber:
    appendText(r, value)
    append(r.output, newLine)

  elif value is object:
    append(r.output, newLine)
    enumInstanceSerializedFields(value, fieldName, fieldValue):
      appendFieldName(r, fieldName, depthLevel + 1)
      appendValueImpl(r, formatItIMPL(fieldValue), depthLevel + 1)

  elif value is string:
    var first = true
    for line in splitLines(value):
      if not first:
        appendIndent(r.output, depthLevel)
      append(r.output, line)
      append(r.output, newLine)
      first = false

  else:
    const typeName = typetraits.name(T)
    {.fatal: "The textblocks format does not support the '" & typeName & "' type".}

  resetColors(r)

template appendValue(r: var LogRecord, val: auto, depthLevel: int) =
  mixin formatItIMPL
  appendValueImpl(r, formatItIMPL val, depthLevel)

proc setProperty*(r: var LogRecord, name: string, value: auto, depthLevel = 0) =
  appendFieldName(r, name, depthLevel)
  appendValue(r, value, depthLevel + 1)

proc initLogRecord*(r: var LogRecord,
                    level: LogLevel,
                    topics, msg: string) =
  mixin append

  r.output = initOutputStream type(r)

  appendLogLevelMarker(r, level)
  writeTs(r)

  append(r.output, " ")
  applyStyle(r, styleBright)
  append(r.output, msg)
  resetColors(r)

  append(r.output, "\n")

  if topics.len > 0:
    setProperty(r, "topics", topics)

template setFirstProperty*(r: var LogRecord, name: string, value: auto) =
  setProperty(r, name, value)

proc flushRecord*(r: var LogRecord) =
  when stackTracesEnabled:
    if r.exception != nil:
      append(r.output, static(indentStr & "--" & newLine))
      appendStackTrace(r)

  append(r.output, newLine)

  flushOutput r.OutputKind, r.output

