import
  chronicles

type
  AttestationData* = object
    peer*: Peer
    attestation*: string
    signature*: string

  Peer* = object
    privData: seq[int]
    name*: string

chronicles.expandIt(AttestationData):
  attestation = it.attestation
  peer = it.peer

  # This shouldn't be renamed
  it = "not renamed"

  # But the quote syntax can be used to derive names from the original property name
  `it sig` = it.signature
  `it` = "renamed"
  `"complex_" it "_concatenation"` = Peer(name: "X")

chronicles.formatIt(Peer):
  it.name

