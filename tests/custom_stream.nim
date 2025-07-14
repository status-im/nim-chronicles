import
  chronicles

type
  MyRecord[Output] = object
    output*: Output
    first*: bool

template initLogRecord*(r: var MyRecord, lvl: LogLevel,
                        topics: string, name: string) =
  r.output.append "[", $lvl, "] ", name, ": "
  r.first = true

template setProperty*(r: var MyRecord, key: string, val: auto) =
  if r.first:
    r.output.append " ("
    r.first = false
  else:
    r.output.append(" ,")
  r.output.append key, "=", $val

template flushRecord*(r: var MyRecord) =
  if not r.first:
    r.output.append ")"
  r.output.append "\n"

  r.output.flushOutput

customLogStream myStream[MyRecord[StdOutOutput]]

var x = 10

proc main =
  logScope:
    stream = myStream
    key = "val"

  info "inside main"

info("before main", a = 1, b = 3)

main()

info "after main"

myStream.warn "exiting"

