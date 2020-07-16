import
  strutils,
  faststreams/[outputs, textio],
  options, log_output

const
  controlChars =  {'\x00'..'\x1f'}
  extendedAsciiChars = {'\x7f'..'\xff'}
  escapedChars*: set[char] = strutils.NewLines + {'"', '\\'} + controlChars + extendedAsciiChars
  quoteChars*: set[char] = {' ', '='}

func containsEscapedChars*(str: string|cstring): bool =
  for c in str:
    if c in escapedChars:
      return true
  return false

func needsQuotes*(str: string|cstring): bool =
  for c in str:
    if c in quoteChars:
      return true
  return false

proc writeEscapedString*(output: OutputStream, str: string|cstring) =
  for c in str:
    case c
    of '"': output.write "\\\""
    of '\\': output.write "\\\\"
    of '\r': output.write "\\r"
    of '\n': output.write "\\n"
    else:
      const hexChars = "0123456789abcdef"
      if c >= char(0x20) and c <= char(0x7e):
        output.write c
      else:
        output.write("\\x")
        output.write hexChars[int(c) shr 4 and 0xF]
        output.write hexChars[int(c) and 0xF]

template appendLogLevelMarker*(r: var auto, lvl: LogLevel) =
  when r.colors != NoColors:
    let (color, bright) = levelToStyle(lvl)
    setFgColor(r, color, bright)

  append(r.output, shortName lvl)
  resetColors(r)

template appendChar*(r: var auto, c: static char) =
  when r.output is OutputStream:
    write(r.output, c)
  else:
    append(r.output, $c)

template appendText*(r: var auto, value: auto) =
  when r.output is OutputStream:
    writeText(r.output, value)
  else:
    append(r.output, $value)

proc appendStackTrace*(r: var auto) =
  for entry in getStackTraceEntries(r.exception):
    append(r.output, indentStr)
    appendText(r.output, entry.filename)
    appendChar(r, '(')
    appendText(r, entry.line)
    append(r.output, ") ")
    appendText(r, entry.procname)
    append(r.output, newLine)

