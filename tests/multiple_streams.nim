import chronicles

logScope:
  stream = "foo"

proc fooStreamer =
  info "logging to foo"

logScope:
  stream = "bar"

proc main =
  dynamicLogScope(reqId = 10, userId = 20):
    info "dynamic scope starts"
    fooStreamer()
    info "dynamic scope ends"

  fooStreamer()

  warn "about to exit main"

main()

