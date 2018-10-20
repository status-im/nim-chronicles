import
  chronicles

type
  MyRecord[Output] = object
    output*: Output

template initLogRecord*(r: var MyRecord, lvl: LogLevel,
                        topics: string, name: string) =
  r.output.append "[", $lvl, "] ", name, ": "

template setPropertyImpl(r: var MyRecord, key: string, val: auto) =
  r.output.append key, "=", $val

template setFirstProperty*(r: var MyRecord, key: string, val: auto) =
  r.output.append " ("
  r.setPropertyImpl(key, val)

template setProperty*(r: var MyRecord, key: string, val: auto) =
  r.output.append ", "
  r.setPropertyImpl(key, val)

template flushRecord*(r: var MyRecord) =
  r.output.append ")\n"
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

