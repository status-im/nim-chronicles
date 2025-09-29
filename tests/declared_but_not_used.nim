import
  chronicles

try:
  discard
except CatchableError as exc:
  debug "test", msg=exc.msg
