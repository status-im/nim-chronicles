mode = ScriptMode.Verbose

packageName   = "chronicles"
version       = "0.12.4"
author        = "Status Research & Development GmbH"
description   = "A crafty implementation of structured logging for Nim"
license       = "Apache License 2.0"
skipDirs      = @["tests"]

requires "nim >= 2.0.16"
requires "faststreams >= 0.3.0"
requires "serialization >= 0.5.0"
requires "json_serialization >= 0.4.0" # Only needed for json outputs

# Allow old nimble versions to parse this nimble file
requires "testutils >= 0.8.0"


task test, "run CPU tests":
  when defined(windows):
    exec "ntu.cmd test tests"
  else:
    exec "ntu test tests"
