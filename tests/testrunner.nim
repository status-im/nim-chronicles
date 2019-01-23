import os, osproc, re, strutils, terminal, times, pegs
import test_config, test_helpers

# Testrunner to run tests for chronicles library
# However, could in theory be used to run any test that needs to check
# compile time or runtime output
#
# The runner will look recursively for all *.test files at given path.
# A test file should have at minimum a program name. This is the name of the nim
# source minus the .nim extension)
#
# Code is here and there influenced by nim testament tester and unittest module.

const
  # defaultOptions = "--verbosity:1 --warnings:off --hint[Processing]:off " &
  #                  "--hint[Conf]:off --hint[XDeclaredButNotUsed]:off " &
  #                  "--hint[Link]:off --hint[Pattern]:off"
  defaultOptions = "--verbosity:1 --warnings:off "

type
  TestStatus* = enum
    OK,
    FAILED,
    SKIPPED,
    INVALID

# If needed pass more info to the logresult via a TestResult object
  # TestResult = object
  #   status: TestStatus
  #   compileTime: float
  #   fileSize: uint

  TestError* = enum
    SourceFileNotFound,
    ExeFileNotFound,
    OutputFileNotFound,
    CompileError,
    RuntimeError,
    OutputsDiffer,
    FileSizeTooLarge,
    CompileErrorDiffers

proc logFailure(test: TestSpec, error: TestError, data: varargs[string] = [""]) =
  case error
    of SourceFileNotFound:
      styledEcho(fgYellow, styleBright, "source file not found: ",
                 resetStyle, test.program.addFileExt(".nim"))
    of ExeFileNotFound:
      styledEcho(fgYellow, styleBright, "file not found: ",
                 resetStyle, test.program.addFileExt(ExeExt))
    of OutputFileNotFound:
      styledEcho(fgYellow, styleBright, "file not found: ",
                 resetStyle, data[0])
    of CompileError:
      styledEcho(fgYellow, styleBright, "compile error:\p",
                 resetStyle, data[0])
    of RuntimeError:
      styledEcho(fgYellow, styleBright, "runtime error:\p",
                 resetStyle, data[0])
    of OutputsDiffer:
      styledEcho(fgYellow, styleBright, "outputs are different:\p",
                 resetStyle,"Expected output to $#:\p$#" % [data[0], data[1]],
                            "Resulted output to $#:\p$#" % [data[0], data[2]])
    of FileSizeTooLarge:
      styledEcho(fgYellow, styleBright, "file size is too large: ",
                 resetStyle, data[0] & " > " & $test.maxSize)
    of CompileErrorDiffers:
      styledEcho(fgYellow, styleBright, "compile error is different:\p",
                 resetStyle, data[0])

  styledEcho(fgCyan, styleBright, "command: ", resetStyle,
             "nim c $#$#$#" % [defaultOptions, test.flags,
                                 test.program.addFileExt(".nim")])

proc logResult(testName: string, status: TestStatus, time: float) =
  var color = case status
              of OK: fgGreen
              of FAILED: fgRed
              of SKIPPED: fgYellow
              of INVALID: fgRed
  styledEcho(styleBright, color, "[", $status, "] ",
             resetStyle, testName,
             fgYellow, " ", time.formatFloat(ffDecimal, 3), " s")

template time(duration, body): untyped =
  let t0 = epochTime()
  block:
    body
  duration =  epochTime() - t0

proc cmpOutputs(test: TestSpec, stdout: string): TestStatus =
  result = OK
  for output in test.outputs:
    var testOutput: string
    if output.name == "stdout":
      testOutput = stdout
    else:
      if not existsFile(output.name):
        logFailure(test, OutputFileNotFound, output.name)
        result = FAILED
        continue

      testOutput = readFile(output.name)

    # Would be nice to do a real diff here instead of simple compare
    if test.timestampPeg.len > 0:
      if not cmpIgnorePegs(testOutput, output.expectedOutput, peg(test.timestampPeg), pegXid):
        logFailure(test, OutputsDiffer, output.name, output.expectedOutput, testOutput)
        result = FAILED
    else:
      if not cmpIgnoreDefaultTimestamps(testOutput, output.expectedOutput):
        logFailure(test, OutputsDiffer, output.name, output.expectedOutput, testOutput)
        result = FAILED

    if output.name != "stdout":
      removeFile(output.name)

proc compile(test: TestSpec): TestStatus =
  let source = test.program.addFileExt(".nim")
  if not existsFile(source):
    logFailure(test, SourceFileNotFound)
    return FAILED

  let cmd = "nim c $#$#$#" % [defaultOptions, test.flags, source.quoteShell]
  let c = parseCmdLine(cmd)
  var p = startProcess(command=c[0], args=c[1.. ^1],
                       options={poStdErrToStdOut, poUsePath})
  let compileInfo = parseCompileStream(p, p.outputStream)
  close(p)

  if compileInfo.exitCode != 0:
    if test.compileError.len == 0:
      logFailure(test, CompileError, compileInfo.fullMsg)
      return FAILED
    else:
      if test.compileError == compileInfo.msg and
         (test.errorFile.len == 0 or test.errorFile == compileInfo.errorFile) and
         (test.errorLine == 0 or test.errorLine == compileInfo.errorLine) and
         (test.errorColumn == 0 or test.errorColumn == compileInfo.errorColumn):
        return OK
      else:
        logFailure(test, CompileErrorDiffers, compileInfo.fullMsg)
        return FAILED

  # Lets also check file size here as it kinda belongs to the compilation result
  if test.maxSize != 0:
    var size = getFileSize(test.program.addFileExt(ExeExt))
    if size > test.maxSize:
      logFailure(test, FileSizeTooLarge, $size)
      return FAILED

  return OK

proc execute(test: TestSpec): TestStatus =
  let program = test.program.addFileExt(ExeExt)
  if not existsFile(program):
    logFailure(test, ExeFileNotFound)
    return FAILED

  let (output, exitCode) = execCmdEx(CurDir & DirSep & program.quoteShell)

  if exitCode != 0:
    # parseExecuteOutput() # Need to parse the run time failures?
    logFailure(test, RuntimeError, output)
    return FAILED
  else:
    return test.cmpOutputs(output)

# Get rid of re dependency?
proc scanTestPath(path: string): seq[string] =
  result = @[]

  if fileExists(path):
    result.add(path)
  else:
    for file in walkDirRec path:
      if file.match re".*\.test":
        result.add(file)

proc test(config: TestConfig, testPath: string): TestStatus =
  var test: TestSpec
  var duration: float

  time duration:
    test = parseTestFile(testPath)
    if test.program.len == 0: # a program name is bare minimum of a test file
      result = INVALID
      break
    if test.skip or hostOS notin test.os or config.shouldSkip(test.name):
      result = SKIPPED
      break

    result = test.compile()
    if result != OK or test.compileError.len > 0:
      break

    result = test.execute()
    removeFile(test.program.addFileExt(ExeExt))

  logResult(test.name, result, duration)

proc main() =
  let config = processArguments()
  let testFiles = scanTestPath(config.path)
  var successful, skipped = 0

  if testFiles.len == 0:
    styledEcho(styleBright, "No test files found")
    program_result = 1
    return

  for testFile in testFiles:
    # Here we could do multithread or multiprocess
    # but we will have to work with different nim caches per test
    # and also the executables have to be in a unique location as several tests
    # can use the same source
    var result = test(config, testFile)
    if result == OK:
      successful += 1
    elif result == SKIPPED:
      skipped += 1

  styledEcho(styleBright, "Finished run: $#/$# tests successful" %
                          [$successful, $(testFiles.len - skipped)])
  program_result = testFiles.len - successful - skipped

when isMainModule:
  main()
