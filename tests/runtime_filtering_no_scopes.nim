import chronicles

proc foo =
  info "from foo"

proc bar =
  info "from bar"

echo "> start by printing both:"

foo()
bar()

echo "> set global log level to WARN; info() is now disabled:"
setLogLevel(WARN)

foo()
bar()
