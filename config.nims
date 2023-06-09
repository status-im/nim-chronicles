# begin Nimble config (version 1)
when fileExists("nimble.paths"):
  include "nimble.paths"
# end Nimble config

when (NimMajor, NimMinor) < (1, 6):
  switch("styleCheck", "hint")
else:
  switch("styleCheck", "error")
