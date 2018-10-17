import os, parsecfg, parseopt, strutils, streams

const
  Usage = """Usage:
  testrunner [options] path
  Run the test(s) specified at path. Will search recursively for test files
  provided path is a directory.
Options:
  --targets:"c c++ js objc" [Not implemented] run tests for specified targets
  --help                    display this help and exit"""

type
  TestConfig* = object
    path*: string

  TestSpec* = object
    name*: string
    skip*: bool
    program*: string
    flags*: string
    outputs*: seq[tuple[name: string, expectedOutput: string]]
    timestampPeg*: string
    errorMsg*: string
    maxSize*: int64
    compileError*: string
    errorFile*: string
    errorLine*: int
    errorColumn*: int
    os*: seq[string]

proc processArguments*(): TestConfig =
  var opt = initOptParser()
  var length = 0
  for kind, key, value in opt.getopt():
    case kind
    of cmdArgument:
      if result.path == "":
        result.path = key
    of cmdLongOption, cmdShortOption:
      inc(length)
      case key.toLowerAscii()
        of "help", "h": quit(Usage, QuitSuccess)
        of "targets", "t": discard # not implemented
        else: quit(Usage)
    of cmdEnd:
      quit(Usage)

  if result.path == "":
    quit(Usage)

proc defaults(result: var TestSpec) =
  result.os = @["linux", "macosx", "windows"]

proc parseTestFile*(filePath:string): TestSpec =
  result.defaults()
  result.name = extractFilename(filePath)
  var f = newFileStream(filePath, fmRead)
  var outputSection = false
  if f != nil:
    var p: CfgParser
    open(p, f, filePath)
    while true:
      var e = next(p)
      case e.kind
      of cfgEof:
        break
      of cfgSectionStart:
        if e.section.cmpIgnoreCase("Output") == 0:
          outputSection = true
      of cfgKeyValuePair:
        if outputSection:
          result.outputs.add((e.key, e.value))
        else:
          case e.key
          of "program":
            result.program = e.value
          of "timestamp_peg":
            result.timestampPeg = e.value
          of "max_size":
            if e.value.isDigit:
              result.maxSize = parseInt(e.value)
            else:
              echo("Parsing warning: value of " & e.key &
                   " is not a number (value = " & e.value & ").")
          of "compile_error":
            result.compileError = e.value
          of "error_file":
            result.errorFile = e.value
          of "os":
            result.os = e.value.normalize.split({','} + Whitespace)
          else:
            result.flags &= ("-d:$#:$#" % [e.key, e.value]).quoteShell & " "
      of cfgOption:
        case e.key
        of "skip":
          result.skip = true
        else:
          result.flags &= ("--$#:$#" % [e.key, e.value]).quoteShell & " "
      of cfgError:
        echo("Parsing warning:" & e.msg)
    close(p)
    if result.program == "":
      echo("Parsing error: no program value")
  else:
    echo("Parsing error: cannot open " & filePath)
