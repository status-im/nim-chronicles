import xmltree, chronicles

type XmlRecord[Output] = object
  output*: Output

template initLogRecord*(r: var XmlRecord, lvl: LogLevel,
                        topics: string, name: string) =
  r.output.append "<event type=\"", escape(name), "\" severity=\"", $lvl, "\">\n"

template setProperty*(r: var XmlRecord, key: string, val: auto) =
  r.output.append textBlockIndent, "<", key, ">", escape($val), "</", key, ">\n"

template setFirstProperty*(r: var XmlRecord, key: string, val: auto) =
  r.setProperty key, val

template flushRecord*(r: var XmlRecord) =
  r.output.append "</event>\n"
  r.output.flushOutput

customLogStream xmlStream[XmlRecord[StdOutOutput]]

publicLogScope:
  stream = xmlStream

