import chronicles

func main =
  trace "effect-free"

main()

# issue #92
proc test() {.raises: [Defect].} =
  error "should not raises exception"

test()
