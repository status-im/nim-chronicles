#!/usr/bin/env bash

# Copyright (c) 2025 Status Research & Development GmbH.
# Licensed under either of:
# - Apache License, version 2.0
# - MIT license
# at your option.

output=$(nim c -c -d:release tests/declared_but_not_used 2>&1 | grep "XDeclaredButNotUsed" | grep "exc")
if [[ -n "$output" ]]; then
  echo "Error, XDeclaredButNotUsed should not printed: $output"
  exit 2
fi
