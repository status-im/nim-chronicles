mode = ScriptMode.Verbose

packageName   = "chronicles"
version       = "0.4.1"
author        = "Status Research & Development GmbH"
description   = "A crafty implementation of structured logging for Nim"
license       = "Apache License 2.0"
skipDirs      = @["tests"]

requires "nim >= 0.18.1"

task test, "run CPU tests":
  cd "tests"
  exec "nim c -r testrunner ."

