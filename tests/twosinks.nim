import chronicles

var evals = 0

proc evalMe(): int =
  evals += 1
  evals

proc main() =
  info "info", evals = evalMe()
  warn "warn", evals = evalMe()
  error "error", evals = evalMe()

echo "two default sinks => 3 evals"
main()

echo "fatal/default => 3 evals"
setLogLevel(LogLevel.FATAL, 0)
main()

echo "fatal/fatal => 0 evals"
setLogLevel(LogLevel.FATAL, 1)
main()

echo "default/fatal => 3 evals"
setLogLevel(LogLevel.INFO, 0)
main()
