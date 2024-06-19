
{.push raises: [].}

import std/[times, math]
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

proc fromEpochDay(epochday: int64):
    tuple[monthday: MonthdayRange, month: Month, year: int] =
  var z = epochday
  z.inc 719468
  let
    era = (if z >= 0: z else: z - 146096) div 146097
    doe = z - era * 146097
    yoe = (doe - doe div 1460 + doe div 36524 - doe div 146096) div 365
    y = yoe + era * 400
    doy = doe - (365 * yoe + yoe div 4 - yoe div 100)
    mp = (5 * doy + 2) div 153
    d = doy - (153 * mp + 2) div 5 + 1
    m = mp + (if mp < 10: 3 else: -9)
  (d.MonthdayRange, m.Month, (y + ord(m <= 2)).int)

proc initDateTime(zt: ZonedTime, zone: Timezone): DateTime =
  ## Create a new `DateTime` using `ZonedTime` in the specified timezone.
  let
    adjTime = zt.time - initDuration(seconds = zt.utcOffset)
    s = adjTime.toUnix
    epochday = floorDiv(s, 86_400) #secondsInDay

  var rem = s - epochday * 86_400 # secondsInDay
  let hour = rem div 3600 # secondsInHour
  rem = rem - hour * 3600 # secondsInHour
  let minute = rem div 60 # secondsInMin
  rem = rem - minute * 60 # secondsInMin
  let second = rem

  let (d, m, y) = fromEpochDay(epochday)

  dateTime(y, m, d, hour, minute, second, zt.time.nanosecond, zone)

proc fastAdd*(dt: DateTime, dur: Duration): DateTime =
  let zt = ZonedTime(
    time: dt.toTime() + dur, utcOffset: dt.utcOffset, isDst: dt.isDst)
  initDateTime(zt, dt.timezone)

proc getFastTime*(): times.Time =
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
