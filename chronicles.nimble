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
requires "testutils >= 0.8.4"

let flags = getEnv("NIMFLAGS", "") # Extra flags for the compiler
let platform = getEnv("PLATFORM", "")
let ntu = when defined(windows): "ntu.cmd" else: "ntu"

proc run(args: string, cmdArgs = "") =
  try:
    putEnv("NIMFLAGS", flags & " " & args)  # Apply to programs compiled by ntu
    exec ntu & " test " & cmdArgs & " tests"
  finally:
    putEnv("NIMFLAGS", flags)

task test, "Run all tests":
  run "--mm:refc"
  run "--mm:orc"

task test_asan, "Run all tests with ASAN":
  if platform != "x86":
    # https://clang.llvm.org/docs/AddressSanitizer.html
    putEnv("ASAN_OPTIONS", "detect_leaks=0:detect_stack_use_after_return=1")
    # https://clang.llvm.org/docs/UndefinedBehaviorSanitizer.html
    putEnv("UBSAN_OPTIONS", "print_stacktrace=1")
    let asanArgs =
      " --mm:orc -d:useMalloc --cc:clang --debugger:native" &
      " --passC:-fsanitize=address,undefined" &
      " --passL:-fsanitize=address,undefined" &
      " --passC:-fno-sanitize-recover=undefined" &
      " --passC:-fno-sanitize-merge" &
      " --passC:-fno-omit-frame-pointer"
    run asanArgs, "--exclude:size_check_debug,size_check_release,release_opt_size"
