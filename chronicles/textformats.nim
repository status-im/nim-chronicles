import
  stew/shims/macros,
  faststreams/outputs,
  ./[ansicolors, log_output, options, timestamp]

from std/terminal import ansiResetCode, ForegroundColor, Style

export outputs, ansiResetCode, ForegroundColor, Style

type TextLogRecord*[Output; format: static[FormatSpec]] {.inheritable, pure.} = object
  output*: Output
  stream*: OutputStream

proc writeEscapedString*(stream: OutputStream, str: string | cstring) =
  for c in str:
    case c
    of '"':
      stream.write "\\\""
    of '\\':
      stream.write "\\\\"
    of '\r':
      stream.write "\\r"
    of '\n':
      stream.write "\\n"
    else:
      const hexChars = "0123456789abcdef"
      if c >= char(0x20) and c <= char(0x7e):
        stream.write c
      else:
        stream.write("\\x")
        stream.write hexChars[int(c) shr 4 and 0xF]
        stream.write hexChars[int(c) and 0xF]

const
  propColor* = fgBlue
  topicsColor* = fgYellow

template setFgColor*(record: TextLogRecord, color, brightness) =
  mixin deref
  when record.format.colors == AnsiColors:
    try:
      writeFgColor(record.stream, color, brightness)
    except ValueError:
      discard
  elif record.format.colors == AutoColors:
    if record.output.colors:
      try:
        writeFgColor(record.stream, color, brightness)
      except ValueError:
        discard

template resetColors*(record: TextLogRecord) =
  when record.format.colors == AnsiColors:
    writeStyleReset(record.stream)
  elif record.format.colors == AutoColors:
    if record.output.colors:
      writeStyleReset(record.stream)

template applyStyle*(record: TextLogRecord, style) =
  when record.format.colors == AnsiColors:
    record.stream.writeStyle(style)
  elif record.format.colors == AutoColors:
    if record.output.colors:
      record.stream.writeStyle(style)

template levelToStyle*(lvl: LogLevel): untyped =
  # Bright Black is gray
  # Light green doesn't display well on white consoles
  # Light yellow doesn't display well on white consoles
  # Light cyan is darker than green

  case lvl
  of TRACE:
    (fgWhite, false)
  of DEBUG:
    (fgBlack, true)
  # Bright Black is gray
  of INFO:
    (fgCyan, true)
  of NOTICE:
    (fgMagenta, false)
  of WARN:
    (fgYellow, false)
  of ERROR:
    (fgRed, true)
  of FATAL:
    (fgRed, false)
  of NONE:
    (fgWhite, false)

template writeLogLevel*(r: var TextLogRecord, lvl: LogLevel) =
  when colorScheme != NoColors:
    let (color, bright) = levelToStyle(lvl)
    setFgColor(s, colorScheme, color, bright)

  s.write shortName(lvl)
  resetColors(s, colorScheme)

template writeSpaceAndTs*(record: var TextLogRecord) =
  when record.format.timestamps != NoTimestamps:
    record.stream.write " "
    record.stream.writeTimestamp(record.format.timestamps)

template writeLogLevelMarker*(r: var TextLogRecord, lvl: LogLevel) =
  when r.format.colors != NoColors:
    let (color, bright) = levelToStyle(lvl)
    setFgColor(r, color, bright)

  write(r.stream, shortName lvl)
  resetColors(r)

macro isDefaultDollar*(call: typed): bool =
  ## Determine if `$` is the default one for object/tuple or a specialization.
  # `call` should be the expression `$value` where `$` could be a template
  # but in the non-overriden case will be a generic proc constrained to
  # objects/tuples (at the time of writing)
  let impl = call[0].getImpl()

  # Match `proc `$`[T: object]` or `$`[T: tuple]` which should hopefully
  # survive any system refactoring
  newLit(
    impl.kind in {nnkProcDef, nnkFuncDef} and impl[5].kind == nnkBracket and
      impl[5][1].kind == nnkGenericParams and impl[5][1][0].kind == nnkIdentDefs and
      impl[5][1][0][1].kind in {nnkObjectTy, nnkTupleClassTy}
  )
