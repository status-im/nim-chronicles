import
  chronicles, custom_formatters_types

var a = AttestationData(peer: Peer(name: "Peer 1"),
                        attestation: "some attestation",
                        signature: "some signature")

info  "Got attestation 1", a
warn "Got attestation 2", attestation = a

