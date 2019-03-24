import
  macros, tables, strformat, options

type
  BindingsSet* = Table[string, NimNode]
  FinalBindingsSet* = OrderedTable[string, NimNode]
  AssignmentsContext* = enum acScopeBlock, acLogStatement

proc id*(key: string, public = false): NimNode =
  result = ident key
  if public: result = postfix(result, "*")

iterator assignments*(n: NimNode, c: AssignmentsContext): (string, NimNode) =
  # extract the assignment pairs from a block with assigments
  # or a call-site with keyword arguments.
  for child in n:
    if child.kind in {nnkAsgn, nnkExprEqExpr}:
      let name = $child[0]
      let value = child[1]
      yield (name, value)

    elif child.kind in {nnkIdent, nnkSym}:
      yield ($child, child)

    else:
      if c == acScopeBlock:
        error "A scope definition should consist only of key-value assignments"
      else:
        error "Log statements should use keyword parameters to specify the log event properties"

proc scopeAssignments*(scopeBody: NimNode): NimNode =
  if scopeBody.len > 1:
    result = scopeBody[1]
  else:
    result = newStmtList()

proc scopeRevision*(scopeBody: NimNode): int =
  # get the revision number from a `activeChroniclesScope` body
  var revisionNode = scopeBody[0]
  result = int(revisionNode.intVal)

proc lastScopeBody*(scopes: NimNode): NimNode =
  # get the most recent `activeChroniclesScope` body from a symChoice node
  case scopes.kind
  of nnkCall:
    result = lastScopeBody(scopes[^1])
  of {nnkClosedSymChoice, nnkOpenSymChoice}:
    var bestScopeRev = 0
    doAssert scopes.len > 0
    for scope in scopes:
      let scopeBody = scope.getImpl.body
      let rev = scopeBody.scopeRevision
      if result == nil or rev > bestScopeRev:
        result = scopeBody
        bestScopeRev = rev
  of nnkSym:
    result = scopes.getImpl.body
  else:
    error &"Unexpected scope AST node ({scopes.kind}). Please report an issue."

template finalLexicalBindings*(scopes: NimNode): NimNode =
  scopes.lastScopeBody.scopeAssignments

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

proc skipTypedesc*(n: NimNode): NimNode =
  result = n
  if result.kind == nnkBracketExpr and result.len == 2 and
     (eqIdent(result[0], "type") or eqIdent(result[0], "typedesc")):
    result = result[1]

proc clearEmptyVarargs*(args: NimNode) =
  # Nim will sometimes do something silly - it will convert our varargs
  # into an empty array. We need to detect this case and handle it:
  if args.len == 1 and args[0].kind == nnkHiddenStdConv:
    args.del 0

