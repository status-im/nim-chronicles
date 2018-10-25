mode = ScriptMode.Verbose

packageName   = "chronicles"
version       = "0.3.2"
author        = "Status Research & Development GmbH"
description   = "A crafty implementation of structured logging for Nim"
license       = "Apache License 2.0"
skipDirs      = @["tests"]
bin           = @["chronicles/bin/chronicles_tail"]

requires "nim >= 0.18.1",
         "compiler",
         "https://github.com/surf1nb1rd/nim-prompt"

task test, "run CPU tests":
  cd "tests"
  exec "nim c -r testrunner ."

