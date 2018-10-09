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
  # peg for any float with 4 or more digits after the decimal as currently the
  # unix timestamp is not necessary 6 digits after decimal in chronicles
  # Not ideal - could also improve by checking for the location in the line
  pegUnixTimestamp = peg"{\d+} '.' {\d\d\d\d} {\d*} \s"
  # peg for timestamp with format yyyy-MM-dd HH:mm:sszzz
  pegRfcTimestamp = peg"{\d\d\d\d} '-' {\d\d} '-' {\d\d} ' ' {\d\d} ':' {\d\d} ':' {\d\d} {'+' / '-'} {\d\d} ':' {\d\d} \s"

proc cmpIgnorePeg*(a, b: string, peg: Peg): bool =
  return a.replace(peg, "dummy") == b.replace(peg, "dummy")

proc cmpIgnoreTimestamp*(a, b: string, timestamp = ""): bool =
  if timestamp.len == 0:
    return a == b
  else:
    if timestamp == "RfcTime":
      return cmpIgnorePeg(a, b, pegRfcTimestamp)
    elif timestamp == "UnixTime":
      return cmpIgnorePeg(a, b, pegUnixTimestamp)

proc cmpIgnoreDefaultTimestamps*(a, b: string): bool =
  if a == b:
    return true
  elif cmpIgnorePeg(a, b, pegRfcTimestamp):
    return true
  elif cmpIgnorePeg(a, b, pegUnixTimestamp):
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
