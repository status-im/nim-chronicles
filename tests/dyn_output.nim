import chronicles

proc stdoutFlush(logLevel: LogLevel, msg: LogOutputStr) =
  try:
    stdout.write(msg)
    stdout.flushFile()
  except IOError as err:
    logLoggingFailure(cstring(msg), err)

defaultChroniclesStream.outputs[0].writer = stdoutFlush
defaultChroniclesStream.outputs[1].writer = stdoutFlush

var evals: int

proc evalMe(): int =
  evals += 1
  evals

proc main() =
  info "info", evals = evalMe()
  warn "warn", evals = evalMe()
  error "error", evals = evalMe()

main()
