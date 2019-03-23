import chronicles

type CustomException = object of Exception

logStream lines[textlines]

try:
  raise newException(CustomException, "custom message")
except:
  debug "test debug", foo="bar"
  debugException "test debugException", foo="bar"
  errorException "test errorException"
  lines.warnException "test warnException stream"

