import
  macros, tables, strformat, options

type
  Binding* = object
    value*: NimNode
    public*: bool

  BindingsSet* = Table[string, Binding]
  FinalBindingsSet* = OrderedTable[string, Binding]

proc id*(key: string, public = false): NimNode =
  result = newIdentNode(key)
  if public: result = postfix(result, "*")

iterator assignments*(n: NimNode, liftIdentifiers = true): (string, Binding) =
  # extract the assignment pairs from a block with assigments
  # or a call-site with keyword arguments.
  for child in n:
    if child.kind in {nnkAsgn, nnkExprEqExpr}:
      let name = $child[0]
      let value = child[1]
      yield (name, Binding(public: false, value: value))

    elif child.kind in {nnkLetSection, nnkVarSection}:
      for identDef in child:
        var
          name: string
          binding = Binding(public: false, value: identDef[2])

        if identDef[0].kind == nnkPostfix and $identDef[0][0] == "*":
          name = $(identDef[0][1])
          binding.public = true
        else:
          name = $(identDef[0])

        yield (name, binding)

    elif child.kind == nnkIdent and liftIdentifiers:
      yield ($child, Binding(public: false, value: child))

    else:
      error "A scope definitions should consist only of key-value assignments"

proc scopeAssignments*(scopeBody: NimNode): NimNode =
  if scopeBody.len > 1:
    result = scopeBody[1]
  else:
    result = newStmtList()

proc scopeRevision*(scopeBody: NimNode): int =
  # get the revision number from a `chroniclesLexScopeIMPL` body
  var revisionNode = scopeBody[0]
  result = int(revisionNode.intVal)

proc lastScopeBody*(scopes: NimNode): NimNode =
  # get the most recent `chroniclesLexScopeIMPL` body from a symChoice node
  if scopes.kind in {nnkClosedSymChoice, nnkOpenSymChoice}:
    var bestScopeRev = 0
    assert scopes.len > 0
    for scope in scopes:
      var scopeBody = scope.getImpl.body
      let rev = scopeBody.scopeRevision
      if result == nil or rev > bestScopeRev:
        result = scopeBody
        bestScopeRev = rev
  else:
    result = scopes.getImpl.body

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
  if result.kind == nnkBracketExpr and $result[0] in ["type", "typedesc"]:
    result = result[1]

proc clearEmptyVarargs*(args: NimNode) =
  # Nim will sometimes do something silly - it will convert our varargs
  # into an empty array. We need to detect this case and handle it:
  if args.len == 1 and args[0].kind == nnkHiddenStdConv:
    args.del 0

proc expectBoolLit*(v: NimNode): bool =
  if v.kind != nnkIdent or $v notin ["true", "false"]:
    error "bool literal expected", v
  return $v == "true"

