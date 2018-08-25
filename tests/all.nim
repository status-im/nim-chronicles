import chronicles, strutils, unittest


type TestOutput = object

# XXX would be nicer to use something akin to a mock to verify this but 30s of
#     searching didn't reveal anything
var v: string

customLogStream s[TextLineRecord[TestOutput, NoTimestamps, NoColors]]

template append*(o: var TestOutput, s: string) = v.add(s)
template flushOutput*(o: var TestOutput)       = discard

suite "textlines":
  setup:
    v = ""

  test "should quote space":
    s.debug "test", yes = "quote me", no = "noquote"

    check "yes=\"quote me\"" in v
    check "no=noquote" in v

    test "should escape newlines space lines":
      const multiline = """quote
me"""

      s.debug "test", s = multiline

      check "s=\"quote\\nme\"" in v
