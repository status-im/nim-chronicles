import
  macros, tables, strutils,
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
      result.add quote do:
        template chroniclesActiveStreamIMPL: typedesc = `streamId`
    else:
      newScopeDefinition.add newAssignment(newIdentNode(k), v)

  result.add quote do:
    template chroniclesLexScopeIMPL = `newScopeDefinition`

template logScope*(newBindings: untyped) {.dirty.} =
  bind bindSym, mergeScopes, brForceOpen
  mergeScopes(bindSym("chroniclesLexScopeIMPL", brForceOpen),
              newBindings)

template dynamicLogScope*(bindings: varargs[untyped]) {.dirty.} =
  bind bindSym, brForceOpen
  dynamicLogScopeIMPL(bindSym("chroniclesLexScopeIMPL", brForceOpen), bindings)

macro logImpl(activeStream: typed, severity: LogLevel, scopes: typed,
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

  let eventName = logStmtBindings[0]; assert eventName.kind in {nnkStrLit}
  let stream = finalBindings.getStream
  let record = genSym(nskVar, "record")
  let recordType = newIdentNode(stream.recordTypeName)
  let threadId = when compileOption("threads"): newCall("getThreadId")
                 else: newLit(0)

  result = newStmtList()
  result.add quote do:
    var `record`: `recordType`

  for i in 0 ..< stream.sinks.len:
    let recordRef = if stream.sinks.len == 1: record
                    else: newTree(nnkBracketExpr, record, newLit(i))
    result.add quote do:
      initLogRecord(`recordRef`, `severity`, `eventName`)
      setFirstProperty(`recordRef`, "thread", `threadId`)

    for k, v in finalBindings:
      result.add newCall("setProperty", recordRef, newLit(k), v)

  result.add newCall("logAllDynamicProperties", record)
  result.add newCall("flushRecord", record)

template log*(severity: LogLevel, props: varargs[untyped]) {.dirty.} =
  bind logImpl, bindSym, brForceOpen
  logImpl(chroniclesActiveStreamIMPL(),
          severity,
          bindSym("chroniclesLexScopeIMPL", brForceOpen),
          props)

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

