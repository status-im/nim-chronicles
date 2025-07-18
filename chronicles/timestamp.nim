{.push raises: [].}

import
  std/[strutils, times],
  stew/[byteutils, objects],
  faststreams/[outputs, textio],
  ./options

export times, outputs, textio

when defined(macos) or defined(macosx) or defined(osx):
  from posix import Timeval
  proc gettimeofday(
    tp: var Timeval, tzp: pointer = nil
  ) {.importc: "gettimeofday", header: "<sys/time.h>", sideEffect.}

elif defined(windows):
  type FILETIME {.final, pure, completeStruct.} = object
    dwLowDateTime: uint32
    dwHighDateTime: uint32

  proc getSystemTimeAsFileTime*(
    lpSystemTimeAsFileTime: var FILETIME
  ) {.importc: "GetSystemTimeAsFileTime", dynlib: "kernel32", stdcall, sideEffect.}

else:
  const CLOCK_REALTIME_COARSE = 5
  from std/posix import Timespec, Time, clock_gettime

proc getFastTime(): times.Time =
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

var
  cachedMinutes {.threadvar.}: int64
  cachedTimeArray {.threadvar.}: array[17, byte] # "yyyy-MM-dd HH:mm:"
  cachedZoneArray {.threadvar.}: array[6, byte] # "zzz"

proc getSecondsPart(timestamp: times.Time): array[6, char] {.noinit.} =
  let
    sec = timestamp.toUnix() mod 60
    msec = timestamp.nanosecond() div 1_000_000

  result[0] = chr(ord('0') + (sec div 10))
  result[1] = chr(ord('0') + (sec mod 10))

  result[2] = '.'

  let tmp = msec mod 100
  result[3] = chr(ord('0') + (msec div 100))
  result[4] = chr(ord('0') + (tmp div 10))
  result[5] = chr(ord('0') + (tmp mod 10))

proc updateMinutes(timestamp: times.Time, useUtc: static bool) =
  let minutes = timestamp.toUnix() div 60

  if minutes != cachedMinutes:
    cachedMinutes = minutes
    let datetime =
      when useUtc:
        timestamp.utc()
      else:
        timestamp.local()
    block:
      # Cache string representation of first part (without seconds)
      let tmp = datetime.format("yyyy-MM-dd HH:mm:")
      cachedTimeArray = toArray(17, tmp.toOpenArrayByte(0, 16))
    block:
      when not useUtc:
        # Cache string representation of zone part
        let tmp = datetime.format("zzz")
        cachedZoneArray = toArray(6, tmp.toOpenArrayByte(0, 5))

proc writeTimestamp*(
    stream: OutputStream, timestamps: static TimestampScheme
) {.raises: [IOError].} =
  when timestamps in {RfcTime, RfcUtcTime}:
    let timestamp = getFastTime()
    updateMinutes(timestamp, timestamps == RfcUtcTime)

    stream.write cachedTimeArray
    stream.write timestamp.getSecondsPart()
    when timestamps == RfcUtcTime:
      stream.write "Z"
    else:
      stream.write cachedZoneArray
  elif timestamps == UnixTime:
    stream.writeText formatFloat(epochTime(), ffDecimal, 6)
  else:
    {.error: "Unrecognised timestamp format: " & $timestamps.}
