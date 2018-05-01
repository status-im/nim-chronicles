import
  chronicles

type
  MyRecord = object

template initLogRecord*(r: var MyRecord, lvl: LogLevel, name: string) =
  stdout.write "[", lvl, "] ", name, ": "

template setPropertyImpl(r: var MyRecord, key: string, val: auto) =
  stdout.write key, "=", val

template setFirstProperty*(r: var MyRecord, key: string, val: auto) =
  stdout.write " ("
  setPropertyImpl(r, key, val)

template setProperty*(r: var MyRecord, key: string, val: auto) =
  stdout.write ", "
  setPropertyImpl(r, key, val)

template flushRecord*(r: var MyRecord) =
  stdout.write ")\n"

customLogStream myStream[MyRecord]

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

