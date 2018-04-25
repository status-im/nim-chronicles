import
  macros, tables, strutils,
  chronicles/[scope_helpers, dynamic_scope, log_output, options]

export
  dynamic_scope, log_output

type
  BindingsSet = Table[string, NimNode]

template lexScopeSymbolsIMPL* =
  0 # scope revision number

proc actualBody(n: NimNode): NimNode =
  # skip over the double StmtList node introduced in `mergeScopes`
  result = n.body
  if result.kind == nnkStmtList and result[0].kind == nnkStmtList:
    result = result[0]

proc scopeRevision(scopeSymbols: NimNode): int =
  # get the revision number from a `lexScopeSymbolsIMPL` sym
  assert scopeSymbols.kind == nnkSym
  var revisionNode = scopeSymbols.getImpl.actualBody[0]
  result = int(revisionNode.intVal)

proc lastScopeHolder(scopes: NimNode): NimNode =
  # get the most recent `lexScopeSymbolsIMPL` from a symChoice node
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

macro mergeScopes(scopes: typed, newBindings: untyped): untyped =
  var
    bestScope = scopes.lastScopeHolder
    bestScopeRev = bestScope.scopeRevision

  var finalBindings = initTable[string, NimNode]()
  for k, v in assignments(bestScope.getImpl.actualBody, skip = 1):
    finalBindings[k] = v

  for k, v in assignments(newBindings):
    finalBindings[k] = v

  var newScopeDefinition = newStmtList(newLit(bestScopeRev + 1))

  for k, v in finalBindings:
    newScopeDefinition.add newAssignment(newIdentNode(k), v)

  result = quote:
    template lexScopeSymbolsIMPL = `newScopeDefinition`

template logScope*(newBindings: untyped) {.dirty.} =
  bind bindSym, mergeScopes, brForceOpen
  mergeScopes(bindSym("lexScopeSymbolsIMPL", brForceOpen),
              newBindings)

macro logImpl(severity: LogLevel, scopes: typed,
              logStmtProps: varargs[untyped]): untyped =
  if not loggingEnabled: return

  let lexicalScope = scopes.lastScopeHolder.getImpl.actualBody
  var finalBindings = initOrderedTable[string, NimNode]()

  for k, v in assignments(lexicalScope, skip = 1):
    finalBindings[k] = v

  for k, v in assignments(logStmtProps, skip = 1):
    finalBindings[k] = v

  finalBindings.sort(system.cmp)

  var topicsMatch = enabledTopics.len == 0

  if finalBindings.hasKey("topics"):
    let topicsNode = finalBindings["topics"]
    if topicsNode.kind notin {nnkStrLit, nnkTripleStrLit}:
      error "Please specify the 'topics' list as a space separated string literal", topicsNode

    let currentTopics = topicsNode.strVal.split(Whitespace)
    for t in currentTopics:
      if t in disabledTopics:
        return
      if t in enabledTopics:
        topicsMatch = true

  if not topicsMatch:
    return

  let eventName = logStmtProps[0]
  assert eventName.kind in {nnkStrLit}
  let record = genSym(nskVar, "record")

  let threadId = when compileOption("threads"): newCall("getThreadId")
                 else: newLit(0)

  result = quote:
    var `record`: LogOutput
    setEventName(`record`, `severity`, `eventName`)
    setFirstProperty(`record`, "thread", `threadId`)

  for k, v in finalBindings:
    result.add newCall(newIdentNode"setProperty", record, newLit(k), v)

  result.add newCall(newIdentNode"logAllDynamicProperties", record)
  result.add newCall(newIdentNode"flushRecord", record)

template log*(severity: LogLevel, props: varargs[untyped]) {.dirty.} =
  bind logImpl, bindSym, brForceOpen
  logImpl(severity, bindSym("lexScopeSymbolsIMPL", brForceOpen), props)

template logFn(name, severity) =
  template `name`*(props: varargs[untyped]) =
    bind log
    log(severity, props)

logFn debug , LogLevel.DEBUG
logFn info  , LogLevel.INFO
logFn notice, LogLevel.NOTICE
logFn warn  , LogLevel.WARN
logFn error , LogLevel.ERROR
logFn fatal , LogLevel.FATAL

