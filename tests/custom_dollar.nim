import chronicles

type
  Inner = object
    b: int
  ProcForwarded = object
    inner: Inner
  Multiline = object
    first, second: string
  Quoting = object
    text: string

proc `$`(x: ProcForwarded): string = $x.inner
proc `$`(x: Multiline): string = x.first & "\n" & x.second
proc `$`(x: Quoting): string = x.text

var
  procForwarded = ProcForwarded(inner: Inner(b: 2))
  procForwardedSeq = @[procForwarded]
  multiline = Multiline(first: "first line", second: "second line")
  quoting = Quoting(text: "say \"hi\"")

logStream lines[textlines]

lines.info "forwarding proc", procForwarded
lines.info "forwarding proc seq", procForwardedSeq
lines.info "multiline proc", multiline
lines.info "quoting proc", quoting

logStream blocks[textblocks]

blocks.info "forwarding proc", procForwarded
blocks.info "forwarding proc seq", procForwardedSeq
blocks.info "multiline proc", multiline
blocks.info "quoting proc", quoting
