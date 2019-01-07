import chronicles

proc main(arg: int) =
  logScope:
    topics = "main"
    arg
    a = 1

  warn("inside main", b = 10)
  info("inside main", b = 10)
  debug("inside main", b = 10)

proc foo(arg: int) =
  logScope:
    topics = "foo"
    arg

  warn("inside foo", b = 10)
  info("inside foo", b = 10)
  debug("inside foo", b = 10)

proc foobar(arg: int) =
  logScope:
    topics = "foo bar"
    arg

  warn("inside foobar", b = 10)
  info("inside foobar", b = 10)
  debug("inside foobar", b = 10)

main(50)
foo(10)
foobar(20)

info("after main", topics = "general")
info("exiting", msg = "bye bye")
