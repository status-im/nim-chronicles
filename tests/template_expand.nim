import chronicles

type Envelope = object
  sender: string

template expandEnvelope() =
  let sender {.used.} = "template local"
  expandIt(Envelope):
    sender = it.sender

expandEnvelope()

info "expanded", envelope = Envelope(sender: "alice")
