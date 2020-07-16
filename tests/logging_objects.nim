import
  strutils, chronicles

type
  Point = object
    x, y: float

  Triangle = object
    a, b, c: Point
    color: Color

  Color = object
    r, g, b: int

logScope:
  c = Color(r: 12, g: 32, b: 46)

proc main() {.raises: [Defect].} =
  logScope:
    topics = "main"

  var
    a = Point(x: 0, y: 10)
    b = Point(x: 12, y: 32)
    c = Point(x: 15, y: 21)
    red = Color(r: 255)

    t = Triangle(a: a, b: b, c: c, color: red)

  try:
    info "main started", triangle = t, hasBlue = (t.color.b > 0)
    let y = parseInt("abcd")
    info "next line", x = "test", y
  except CatchableError as err:
    error "Failure", err

main()

info("exiting", msg = "bye bye")

