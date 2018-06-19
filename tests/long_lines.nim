import chronicles, strutils

var str = """
some multiline
string
more lines"""

logStream lines[textlines]

lines.info "long info", str
lines.warn "long warning", str

logStream blocks[textblocks]

blocks.info "long info", str
blocks.warn "long warning", str

