
{.push raises: [].}

import std/times
export times

when defined(macos) or defined(macosx) or defined(osx):
  from posix import gettimeofday, Timeval
elif defined(windows):
  type
    FILETIME {.final, pure, completeStruct.} = object
      dwLowDateTime: uint32
      dwHighDateTime: uint32
  proc getSystemTimeAsFileTime*(lpSystemTimeAsFileTime: var FILETIME) {.
       importc: "GetSystemTimeAsFileTime", dynlib: "kernel32", stdcall,
       sideEffect.}
else:
  const CLOCK_REALTIME_COARSE = 5
  from std/posix import Timespec, Time, clock_gettime

proc getFastTime*(): Time =
  when defined(js):
    let
      millis = newDate().getTime()
      seconds = millis div 1_000
      nanos = (millis mod 1_000) * 1_000_000
    initTime(seconds, nanos)
  elif defined(macosx):
    var a {.noinit.}: Timeval
    gettimeofday(a)
    initTime(a.tv_sec.int64, int(a.tv_usec) * 1_000)
  elif defined(windows):
    var f {.noinit.}: FILETIME
    getSystemTimeAsFileTime(f)
    let tmp = uint64(f.dwLowDateTime) or (uint64(f.dwHighDateTime) shl 32)
    fromWinTime(cast[int64](tmp))
  else:
    var ts {.noinit.}: Timespec
    discard clock_gettime(CLOCK_REALTIME_COARSE, ts)
    initTime(int64(ts.tv_sec), int(ts.tv_nsec))
