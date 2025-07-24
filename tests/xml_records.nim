import xmltree, chronicles/[log_output, options, timestamp]

type LogRecord*[Output; format: static[FormatSpec]] = object
  output*: Output

proc initLogRecord*(r: var LogRecord, lvl: LogLevel, topics: string, name: string) =
  r.output.append "<event type=\"", escape(name), "\" severity=\"", $lvl, "\">\n"

proc setProperty*(r: var LogRecord, key: string, val: auto) =
  r.output.append indentStr, "<", key, ">", escape($val), "</", key, ">\n"

proc flushRecord*(r: var LogRecord) =
  r.output.append "</event>", newLine
  r.output.flushOutput
