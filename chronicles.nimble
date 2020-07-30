mode = ScriptMode.Verbose

packageName   = "chronicles"
version       = "0.9.2"
author        = "Status Research & Development GmbH"
description   = "A crafty implementation of structured logging for Nim"
license       = "Apache License 2.0"
skipDirs      = @["tests"]

requires "nim >= 1.2.0"
requires "testutils"
requires "json_serialization"

task test, "run CPU tests":
  when defined(windows):
    # exec "cmd.exe /C ntu.cmd test tests"
    echo "`ntu` doesn't work on Windows"
  else:
    exec "ntu test tests"
