include system/timers

import ../chronicles
export chronicles

func humaneValue*(elapsed: Nanos): string =
  if elapsed > 1000000000:
    $(float(uint64 elapsed) / 1000000000'f) & "s"
  elif elapsed > 1000000:
    $(float(uint64 elapsed) / 1000000'f) & "ms"
  else:
    $(elapsed) & "ns"

template timeIt*(code: untyped): Nanos =
  let t0 = getTicks()
  code
  getTicks() - t0

template logTime*(logLevel: untyped,
                  description: static string,
                  code: untyped) {.dirty.} =
  let time = timeIt: code
  logLevel description, t = humaneValue(time)

