import
  macros, tables, strformat, options

type
  BindingsSet* = Table[string, NimNode]
  FinalBindingsSet* = OrderedTable[string, NimNode]

iterator assignments*(n: NimNode, skip = 0): (string, NimNode) =
  # extract the assignment pairs from a block with assigments
  # or a call-site with keyword arguments.
  for i in skip ..< n.len:
    let child = n[i]
    if child.kind in {nnkAsgn, nnkExprEqExpr}:
      let name = $child[0]
      let value = child[1]
      yield (name, value)
    else:
      error "A scope definitions should consist only of key-value assignments"

proc actualBody*(n: NimNode): NimNode =
  # skip over the double StmtList node introduced in `mergeScopes`
  result = n.body
  if result.kind == nnkStmtList and result[0].kind == nnkStmtList:
    result = result[0]

proc scopeRevision*(scopeSymbol: NimNode): int =
  # get the revision number from a `chroniclesLexScopeIMPL` sym
  assert scopeSymbol.kind == nnkSym
  var revisionNode = scopeSymbol.getImpl.actualBody[0]
  result = int(revisionNode.intVal)

proc lastScopeHolder*(scopes: NimNode): NimNode =
  # get the most recent `chroniclesLexScopeIMPL` from a symChoice node
  if scopes.kind in {nnkClosedSymChoice, nnkOpenSymChoice}:
    var bestScopeRev = 0
    assert scopes.len > 0
    for scope in scopes:
      let rev = scope.scopeRevision
      if result == nil or rev > bestScopeRev:
        result = scope
        bestScopeRev = rev
  else:
    result = scopes

  assert result.kind == nnkSym

template finalLexicalBindings*(scopes: NimNode): NimNode =
  scopes.lastScopeHolder.getImpl.actualBody

proc handleUserStreamChoice*(n: NimNode): StreamSpec =
  # XXX: This proc could use a lent result once the compiler supports it
  if n.kind != nnkStrLit:
    error "The stream name should be specified as a string literal", n

  let streamName = $n
  for s in config.streams:
    if s.name == streamName:
      return s

  error &"'{streamName}' is not a configured stream name. " &
         "Please refer to the documentation of 'chronicles_streams'", n

proc getStream*(finalBindings: var FinalBindingsSet): StreamSpec {.compileTime.} =
  if finalBindings.hasKey("stream"):
    let streamNode = finalBindings["stream"]
    finalBindings.del("stream")
    return handleUserStreamChoice(streamNode)

  return config.streams[0]

