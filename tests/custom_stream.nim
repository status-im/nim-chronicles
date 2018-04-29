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

logScope:
  stream = "myStream"

info "test"
# myStream.info "info panel"

