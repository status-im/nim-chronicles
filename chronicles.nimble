mode = ScriptMode.Verbose

packageName   = "chronicles"
version       = "0.1.0"
author        = "Status Research & Development GmbH"
description   = "The premier structured logging library for Nim"
license       = "Apache License 2.0"
skipDirs      = @["tests"]

requires "nim >= 0.18.1"

proc configForTests() =
  --hints: off
  --debuginfo
  --path: "."
  --run

task test, "run CPU tests":
  configForTests()
  setCommand "c", "tests/all.nim"

