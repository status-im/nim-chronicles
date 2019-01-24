import os, osproc, strutils, streams, pegs

type
  CompileInfo* = object
    templFile*: string
    errorFile*: string
    errorLine*, errorColumn*: int
    templLine*, templColumn*: int
    msg*: string
    fullMsg*: string
    compileTime*: float
    exitCode*: int

let
  # Error pegs, taken from testament tester
  pegLineTemplate =
    peg"{[^(]*} '(' {\d+} ', ' {\d+} ') ' 'template/generic instantiation from here'.*"
  pegLineError =
    peg"{[^(]*} '(' {\d+} ', ' {\d+} ') ' ('Error') ':' \s* {.*}"
  pegOtherError = peg"'Error:' \s* {.*}"
  pegError = pegLineError / pegOtherError
  pegSuccess = peg"'Hint: operation successful' {[^;]*} '; '  {\d+} '.' {\d+} .*"

  # Timestamp pegs
  # peg for unix timestamp, basically any float with 6 digits after the decimal
  # Not ideal - could also improve by checking for the location in the line
  pegUnixTimestamp = peg"{\d+} '.' {\d\d\d\d\d\d} \s"
  # peg for timestamp with format yyyy-MM-dd HH:mm:sszzz
  pegRfcTimestamp = peg"{\d\d\d\d} '-' {\d\d} '-' {\d\d} ' ' {\d\d} ':' {\d\d} ':' {\d\d} {'+' / '-'} {\d\d} ':' {\d\d} \s"
  # Thread/process id is unpredictable..
  pegXid* = peg"""'tid' (('=') / ('": ') / (': [1m') / (': ') / ('[0m=[94m') / ('>')) \d+"""

proc cmpIgnorePegs*(a, b: string, pegs: varargs[Peg]): bool =
  var
    aa = a
    bb = b
  for peg in pegs:
    aa = aa.replace(peg, "dummy")
    bb = bb.replace(peg, "dummy")

  return aa == bb

proc cmpIgnoreTimestamp*(a, b: string, timestamp = ""): bool =
  if timestamp.len == 0:
    return cmpIgnorePegs(a, b, pegXid)
  else:
    if timestamp == "RfcTime":
      return cmpIgnorePegs(a, b, pegRfcTimestamp, pegXid)
    elif timestamp == "UnixTime":
      return cmpIgnorePegs(a, b, pegUnixTimestamp, pegXid)

proc cmpIgnoreDefaultTimestamps*(a, b: string): bool =
  if cmpIgnorePegs(a, b, pegRfcTimestamp, pegXid):
    return true
  elif cmpIgnorePegs(a, b, pegUnixTimestamp, pegXid):
    return true
  else: return false

# parsing based on testament tester
proc parseCompileStream*(p: Process, output: Stream): CompileInfo =
  result.exitCode = -1
  var line = newStringOfCap(120).TaintedString
  var suc, err, tmpl = ""

  while true:
    if output.readLine(line):
      if line =~ pegError:
       # `err` should contain the last error/warning message
       err = line
      elif line =~ pegLineTemplate and err == "":
       # `tmpl` contains the last template expansion before the error
       tmpl = line
      elif line =~ pegSuccess:
       suc = line

      if err != "":
       result.fullMsg.add(line.string & "\p")
    else:
     result.exitCode = peekExitCode(p)
     if result.exitCode != -1: break

  if tmpl =~ pegLineTemplate:
    result.templFile = extractFilename(matches[0])
    result.templLine = parseInt(matches[1])
    result.templColumn = parseInt(matches[2])
  if err =~ pegLineError:
    result.errorFile = extractFilename(matches[0])
    result.errorLine = parseInt(matches[1])
    result.errorColumn = parseInt(matches[2])
    result.msg = matches[3]
  elif err =~ pegOtherError:
    result.msg = matches[0]
  elif suc =~ pegSuccess:
    result.msg = suc
    result.compileTime = parseFloat(matches[1] & "." & matches[2])

proc parseExecuteOutput*() = discard
