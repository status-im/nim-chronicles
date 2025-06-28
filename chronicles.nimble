mode = ScriptMode.Verbose

packageName   = "chronicles"
version       = "0.11.0"
author        = "Status Research & Development GmbH"
description   = "A crafty implementation of structured logging for Nim"
license       = "Apache License 2.0"
skipDirs      = @["tests"]

requires "nim >= 2.0.16"
requires "json_serialization"

# Allow old nimble versions to parse this nimble file
when NimMajor >= 2:
  taskRequires "test", "testutils"
else:
  requires "testutils"

task test, "run CPU tests":
  when defined(windows):
    exec "ntu.cmd test tests"
  else:
    exec "ntu test tests"
