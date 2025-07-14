import chronicles

func main =
  trace "effect-free"

main()

# issue #92
proc test() {.raises: [].} =
  error "should not raises exception"

test()
