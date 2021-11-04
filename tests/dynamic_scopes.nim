import chronicles

logScope:
  topics = "main"

type
  Seconds = distinct int

proc `$`*(t: Seconds): string = $(t.int) & "s"
proc `%`*(t: Seconds): string = $(t.int)

chronicles.formatIt Seconds: $it

proc main =
  dynamicLogScope(reqId = 10, userId = 20):
    info "test"

  warn("about to exit", timeSpent = 2.Seconds)

main()

