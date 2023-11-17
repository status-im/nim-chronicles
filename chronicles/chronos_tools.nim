import
  chronos,
  ../chronicles

proc catchOrQuit*(error: Exception) =
  if error of CatchableError:
    trace "Async operation ended with a recoverable error", err = error.msg
  else:
    fatal "Fatal exception reached", err = error.msg, stackTrace = getStackTrace()
    quit 1

proc traceAsyncErrors*(fut: FutureBase) =
  fut.addCallback do (arg: pointer):
    if fut.failed():
      catchOrQuit fut.error[]
