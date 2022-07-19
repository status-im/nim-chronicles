mode = ScriptMode.Verbose

packageName   = "chronicles"
version       = "0.10.3"
author        = "Status Research & Development GmbH"
description   = "A crafty implementation of structured logging for Nim"
license       = "Apache License 2.0"
skipDirs      = @["tests"]

requires "nim >= 1.2.0"
requires "testutils"
requires "json_serialization"

task test, "run CPU tests":
  exec "ntu test tests"
