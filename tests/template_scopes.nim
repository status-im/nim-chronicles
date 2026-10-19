import chronicles

template logLocal() =
  let local = 1
  info "log statement", local

template logScopeLocal() =
  let scoped = 2
  logScope:
    scoped
  info "lexical scope"

template logScopeAssignment() =
  let assigned = 3
  logScope:
    assigned = assigned
  info "lexical scope assignment"

template logDynamicScopeLocal() =
  let dynamic = 4
  dynamicLogScope(dynamic):
    info "dynamic scope"

proc logStatement() =
  logLocal()

proc lexicalScope() =
  logScopeLocal()

proc lexicalScopeAssignment() =
  logScopeAssignment()

proc dynamicScope() =
  logDynamicScopeLocal()

logStatement()
lexicalScope()
lexicalScopeAssignment()
dynamicScope()
