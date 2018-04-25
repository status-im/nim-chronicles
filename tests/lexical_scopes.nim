import chronicles

logScope:
  a = 12
  b = "original-b"

logScope:
  x = 16
  b = "overriden-b"

logScope:
  c = 100

proc main =
  logScope:
    c = 10

  logScope:
    z = 20

  info("main started", a = 10, b = "inner-b", d = "some-d")

main()

info("exiting", msg = "bye bye")

