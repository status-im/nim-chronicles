import chronicles

type
  Inner = object
    b: int
  Literal = object
    a: int
  Forwarded = object
    inner: Inner
  ProcForwarded = object
    inner: Inner
  Pair = tuple[a, b: int]
  Multiline = object
    first, second: string
  Quoting = object
    text: string

template `$`(x: Literal): string = "custom"
template `$`(x: Forwarded): string = $x.inner
proc `$`(x: ProcForwarded): string = $x.inner
template `$`(x: Pair): string = "pair"
proc `$`(x: Multiline): string = x.first & "\n" & x.second
proc `$`(x: Quoting): string = x.text

var
  literal = Literal(a: 1)
  forwarded = Forwarded(inner: Inner(b: 2))
  procForwarded = ProcForwarded(inner: Inner(b: 2))
  procForwardedSeq = @[procForwarded]
  pair: Pair = (a: 3, b: 4)
  multiline = Multiline(first: "first line", second: "second line")
  quoting = Quoting(text: "say \"hi\"")

logStream lines[textlines]

lines.info "literal template", literal
lines.info "forwarding template", forwarded
lines.info "forwarding proc", procForwarded
lines.info "forwarding proc seq", procForwardedSeq
lines.info "tuple template", pair
lines.info "multiline proc", multiline
lines.info "quoting proc", quoting

logStream blocks[textblocks]

blocks.info "literal template", literal
blocks.info "forwarding template", forwarded
blocks.info "forwarding proc", procForwarded
blocks.info "forwarding proc seq", procForwardedSeq
blocks.info "tuple template", pair
blocks.info "multiline proc", multiline
blocks.info "quoting proc", quoting
