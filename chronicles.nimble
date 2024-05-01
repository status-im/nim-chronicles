mode = ScriptMode.Verbose

packageName   = "chronicles"
version       = "0.10.3"
author        = "Status Research & Development GmbH"
description   = "A crafty implementation of structured logging for Nim"
license       = "Apache License 2.0"
skipDirs      = @["tests"]

requires "nim >= 1.6.0"
requires "json_serialization"

when NimMajor >= 2:
  taskRequires "test", "testutils"
else:
  requires "testutils"

task test, "run CPU tests":
  exec "ntu.cmd test tests"
