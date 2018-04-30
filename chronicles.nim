import
  macros, tables, strutils, strformat,
  chronicles/[scope_helpers, dynamic_scope, log_output, options]

export
  dynamic_scope, log_output, options

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

when runtimeFilteringEnabled:
  import chronicles/topics_registry
  export setTopicState, TopicState

  proc topicStateIMPL(topicName: static[string]): ptr TopicState =
    var state {.global.}: TopicState
    var dummy {.global.} = registerTopic(topicName, addr(state))
    return addr(state)

  proc runtimeTopicFilteringCode*(topics: seq[string]): NimNode =
    result = newStmtList()
    var
      matchEnabledTopics = genSym(nskVar, "matchEnabledTopics")
      requiredTopicsCount = genSym(nskVar, "requiredTopicsCount")
      topicChecks = newStmtList()

    result.add quote do:
      var `matchEnabledTopics` = registry.totalEnabledTopics == 0
      var `requiredTopicsCount` = registry.totalRequiredTopics

    for topic in topics:
      result.add quote do:
        let s = topicStateIMPL(`topic`)
        case s[]
        of Normal: discard
        of Enabled: `matchEnabledTopics` = true
        of Disabled: return
        of Required: dec `requiredTopicsCount`

    result.add quote do:
      if not `matchEnabledTopics` or `requiredTopicsCount` > 0:
        return
else:
  template setTopicState*(name, state) =
    {.error: "Run-time topic filtering is currently disabled. " &
             "You can enable it by specifying '-d:chronicles_runtime_filtering:on'".}

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

  var enabledTopicsMatch = enabledTopics.len == 0
  var requiredTopicsCount = requiredTopics.len
  var currentTopics: seq[string] = @[]

  if finalBindings.hasKey("topics"):
    let topicsNode = finalBindings["topics"]
    if topicsNode.kind notin {nnkStrLit, nnkTripleStrLit}:
      error "Please specify the 'topics' list as a space separated string literal", topicsNode

    currentTopics = topicsNode.strVal.split(Whitespace)

    for t in currentTopics:
      if t in disabledTopics:
        return
      elif t in enabledTopics:
        enabledTopicsMatch = true
      elif t in requiredTopics:
        dec requiredTopicsCount

  if not enabledTopicsMatch or requiredTopicsCount > 0:
    return

  result = newStmtList()
  when runtimeFilteringEnabled:
    result.add runtimeTopicFilteringCode(currentTopics)

  let
    recordTypeSym = skipTypedesc(recordType.getTypeImpl())
    recordTypeNodes = recordTypeSym.getTypeImpl()
    recordArity = if recordTypeNodes.kind != nnkTupleConstr: 1
                  else: recordTypeNodes.len
    record = genSym(nskVar, "record")
    threadId = when compileOption("threads"): newCall("getThreadId")
               else: newLit(0)

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

