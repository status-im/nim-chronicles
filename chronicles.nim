import
  macros, tables, strutils, strformat,
  chronicles/[scope_helpers, dynamic_scope, log_output, options]

export
  dynamic_scope, log_output

template chroniclesLexScopeIMPL* =
  0 # scope revision number

macro mergeScopes(prevScopes: typed, newBindings: untyped): untyped =
  var
    bestScope = prevScopes.lastScopeHolder
    bestScopeRev = bestScope.scopeRevision

  var finalBindings = initTable[string, NimNode]()
  for k, v in assignments(bestScope.getImpl.actualBody, skip = 1):
    finalBindings[k] = v

  for k, v in assignments(newBindings):
    finalBindings[k] = v

  result = newStmtList()

  var newScopeDefinition = newStmtList(newLit(bestScopeRev + 1))
  for k, v in finalBindings:
    if k == "stream":
      let streamId = newIdentNode($v)
      let errorMsg = &"{v.lineInfo}: {$streamId} is not a recognized stream name"
      result.add quote do:
        when not declared(`streamId`):
          # XXX: how to report the proper line info here?
          {.error: `errorMsg`.}
        elif not isStreamSymbolIMPL(`streamId`):
          {.error: `errorMsg`.}
        template chroniclesActiveStreamIMPL: typedesc = `streamId`
    else:
      newScopeDefinition.add newAssignment(newIdentNode(k), v)

  result.add quote do:
    template chroniclesLexScopeIMPL = `newScopeDefinition`

template logScope*(newBindings: untyped) {.dirty.} =
  bind bindSym, mergeScopes, brForceOpen
  mergeScopes(bindSym("chroniclesLexScopeIMPL", brForceOpen),
              newBindings)

template dynamicLogScope*(recordType: typedesc,
                          bindings: varargs[untyped]) {.dirty.} =
  bind bindSym, brForceOpen
  dynamicLogScopeIMPL(recordType,
                      bindSym("chroniclesLexScopeIMPL", brForceOpen),
                      bindings)

template dynamicLogScope*(bindings: varargs[untyped]) {.dirty.} =
  bind bindSym, brForceOpen
  dynamicLogScopeIMPL(chroniclesActiveStreamIMPL(),
                      bindSym("chroniclesLexScopeIMPL", brForceOpen),
                      bindings)

macro logIMPL(recordType: typedesc,
              eventName: static[string],
              severity: LogLevel,
              scopes: typed,
              logStmtBindings: varargs[untyped]): untyped =
  if not loggingEnabled: return

  let lexicalBindings = scopes.finalLexicalBindings
  var finalBindings = initOrderedTable[string, NimNode]()

  for k, v in assignments(lexicalBindings, skip = 1):
    finalBindings[k] = v

  for k, v in assignments(logStmtBindings, skip = 1):
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

  let
    recordTypeSym = skipTypedesc(recordType.getTypeImpl())
    recordTypeNodes = recordTypeSym.getTypeImpl()
    recordArity = if recordTypeNodes.kind != nnkTupleConstr: 1
                  else: recordTypeNodes.len
    record = genSym(nskVar, "record")
    threadId = when compileOption("threads"): newCall("getThreadId")
               else: newLit(0)

  result = newStmtList()
  result.add quote do:
    var `record`: `recordType`

  for i in 0 ..< recordArity:
    let recordRef = if recordArity == 1: record
                    else: newTree(nnkBracketExpr, record, newLit(i))
    result.add quote do:
      initLogRecord(`recordRef`, `severity`, `eventName`)
      setFirstProperty(`recordRef`, "thread", `threadId`)

    for k, v in finalBindings:
      result.add newCall("setProperty", recordRef, newLit(k), v)

  result.add newCall("logAllDynamicProperties", record)
  result.add newCall("flushRecord", record)

template log*(severity: LogLevel,
              eventName: static[string],
              props: varargs[untyped]) {.dirty.} =

  bind logIMPL, bindSym, brForceOpen
  logIMPL(chroniclesActiveStreamIMPL(), eventName, severity,
          bindSym("chroniclesLexScopeIMPL", brForceOpen), props)

template log*(recordType: typedesc,
              severity: LogLevel,
              eventName: static[string],
              props: varargs[untyped]) {.dirty.} =

  bind logIMPL, bindSym, brForceOpen
  logIMPL(recordType, eventName, severity,
          bindSym("chroniclesLexScopeIMPL", brForceOpen), props)

template logFn(name, severity) {.dirty.} =
  template `name`*(eventName: static[string],
                   props: varargs[untyped]) {.dirty.} =

    bind logIMPL, bindSym, brForceOpen
    logIMPL(chroniclesActiveStreamIMPL(), eventName, severity,
            bindSym("chroniclesLexScopeIMPL", brForceOpen), props)

  template `name`*(recordType: typedesc,
                   eventName: static[string],
                   props: varargs[untyped])  {.dirty.} =

    bind logIMPL, bindSym, brForceOpen
    logIMPL(recordType, eventName, severity,
            bindSym("chroniclesLexScopeIMPL", brForceOpen), props)

logFn debug , LogLevel.DEBUG
logFn info  , LogLevel.INFO
logFn notice, LogLevel.NOTICE
logFn warn  , LogLevel.WARN
logFn error , LogLevel.ERROR
logFn fatal , LogLevel.FATAL

