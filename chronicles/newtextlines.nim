import chronicles
import times
import strformat

type NewTextLinesRecord[Output] = object
  output*: Output

template initLogRecord*(r: var NewTextLinesRecord, lvl: LogLevel,
                        topics: string, name: string) =
  r.output.append $lvl, " ", $now(), " ", alignString(name, 42)

template setProperty*(r: var NewTextLinesRecord, key: string, val: auto) =
  r.output.append " ", key, "=", $val

template setFirstProperty*(r: var NewTextLinesRecord, key: string, val: auto) =
  r.setProperty key, val

template flushRecord*(r: var NewTextLinesRecord) =
  r.output.append "\n"
  r.output.flushOutput

customLogStream newtextlines[NewTextLinesRecord[StdOutOutput]]

publicLogScope:
  stream = newtextlines
