import
  strutils,
  faststreams/[outputs, textio],
  options, log_output

const
  escChars*: set[char] = strutils.NewLines + {'"', '\\'}
  quoteChars*: set[char] = {' ', '='}

proc writeEscapedString*(output: OutputStream, str: string) =
  for c in str:
    case c
    of '"': output.write "\\\""
    of '\\': output.write "\\\\"
    of '\r': output.write "\\r"
    of '\n': output.write "\\n"
    else: output.write c

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

