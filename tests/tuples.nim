import chronicles

var
  named = (a: 1, b: "some multiline\nstring")
  unnamed = (1, "some multiline\nstring")

logStream lines[textlines]

lines.info "named tuple", named
lines.info "unnamed tuple", unnamed

logStream blocks[textblocks]

blocks.info "named tuple", named
blocks.info "unnamed tuple", unnamed
