import
  macros, tables, strutils, strformat,
  chronicles/[scope_helpers, dynamic_scope, log_output, options]

export
  dynamic_scope, log_output, options

template activeChroniclesScope* =
  0 # track the scope revision

macro logScopeIMPL(prevScopes: typed, args: varargs[untyped]): untyped =
  clearEmptyVarargs args
  if args.len == 0: error "logScope expects a block of bindings", args

  result = newStmtList()
  var
    newBindings = args[^1]
    bestScope = prevScopes.lastScopeBody
    bestScopeRev = bestScope.scopeRevision
    hasPublicProp = false
    finalBindings = initTable[string, Binding]()
    newRevision = newLit(bestScopeRev + 1)
    newAssingments = newTree(nnkLetSection)
    isPublicScope = false
    chroniclesExportNode: NimNode

  for i in 0 ..< args.len - 1:
    let arg = args[i]
    if arg.kind == nnkExprEqExpr:
      let
        argName = $(arg[0])
        argVal = arg[1]
      case argName
      of "public":
        isPublicScope = expectBoolLit(argVal)
        if isPublicScope:
          chroniclesExportNode = newTree(nnkExportExceptStmt,
                                         id"chronicles",
                                         id"activeChroniclesScope")
      else:
        error &"unrecognized paramter: {argName}", arg
    else:
      error "logScope expects only named parameters", arg

  for k, v in assignments(bestScope.scopeAssignments):
    finalBindings[k] = v

  for k, v in assignments(newBindings, false):
    if v.public: hasPublicProp = true
    finalBindings[k] = v

  for k, v in finalBindings:
    if k == "stream":
      let value = v.value
      let streamId = id($value)
      let errorMsg = &"{value.lineInfo}: {$streamId} is not a recognized stream name"
      let templateName = id("activeChroniclesStream", v.public or isPublicScope)

      result.add quote do:
        when not declared(`streamId`):
          # XXX: how to report the proper line info here?
          {.error: `errorMsg`.}
        #elif not isStreamSymbolIMPL(`streamId`):
        #  {.error: `errorMsg`.}
        template `templateName`: typedesc = `streamId`

      if chroniclesExportNode != nil:
        chroniclesExportNode.add id"activeChroniclesStream"

    else:
      newAssingments.add newTree(nnkIdentDefs,
                                 id(k, v.public),
                                 newEmptyNode(),
                                 v.value)

  if isPublicScope:
    result.add chroniclesExportNode

  let scopeSymName = id("activeChroniclesScope", isPublicScope)
  result.add quote do:
    template `scopeSymName` =
      `newRevision`
      `newAssingments`

template logScope*(newBindings: varargs[untyped]) {.dirty.} =
  bind bindSym, logScopeIMPL, brForceOpen
  logScopeIMPL(bindSym("activeChroniclesScope", brForceOpen),
               newBindings)

template dynamicLogScope*(recordType: typedesc,
                          bindings: varargs[untyped]) {.dirty.} =
  bind bindSym, brForceOpen
  dynamicLogScopeIMPL(recordType,
                      bindSym("activeChroniclesScope", brForceOpen),
                      bindings)

template dynamicLogScope*(bindings: varargs[untyped]) {.dirty.} =
  bind bindSym, brForceOpen
  dynamicLogScopeIMPL(activeChroniclesStream(),
                      bindSym("activeChroniclesScope", brForceOpen),
                      bindings)

when runtimeFilteringEnabled:
  import chronicles/topics_registry
  export setTopicState, TopicState

  var gActiveLogLevel: LogLevel

  proc setLogLevel*(lvl: LogLevel) =
    gActiveLogLevel = lvl

  proc topicStateIMPL(topicName: static[string]): ptr TopicState =
    var state {.global.}: TopicState
    var dummy {.global.} = registerTopic(topicName, addr(state))
    return addr(state)

  proc runtimeTopicFilteringCode*(logLevel: LogLevel, topics: seq[string]): NimNode =
    result = newStmtList()
    var
      matchEnabledTopics = genSym(nskVar, "matchEnabledTopics")
      requiredTopicsCount = genSym(nskVar, "requiredTopicsCount")
      topicChecks = newStmtList()

    result.add quote do:
      if LogLevel(`logLevel`) < gActiveLogLevel:
        break chroniclesLogStmt

      var `matchEnabledTopics` = registry.totalEnabledTopics == 0
      var `requiredTopicsCount` = registry.totalRequiredTopics

    for topic in topics:
      result.add quote do:
        let s = topicStateIMPL(`topic`)
        case s[]
        of Normal: discard
        of Enabled: `matchEnabledTopics` = true
        of Disabled: break chroniclesLogStmt
        of Required: dec `requiredTopicsCount`

    result.add quote do:
      if not `matchEnabledTopics` or `requiredTopicsCount` > 0:
        break chroniclesLogStmt
else:
  template runtimeFilteringDisabledError =
    {.error: "Run-time topic filtering is currently disabled. " &
             "You can enable it by specifying '-d:chronicles_runtime_filtering:on'".}

  template setTopicState*(name, state) = runtimeFilteringDisabledError
  template setLogLevel*(name, state) = runtimeFilteringDisabledError

macro logIMPL(recordType: typedesc,
              eventName: static[string],
              severity: static[LogLevel],
              scopes: typed,
              logStmtBindings: varargs[untyped]): untyped =
  if not loggingEnabled or severity < enabledLogLevel: return
  clearEmptyVarargs logStmtBindings

  let lexicalBindings = scopes.finalLexicalBindings
  var finalBindings = initOrderedTable[string, Binding]()

  for k, v in assignments(lexicalBindings):
    finalBindings[k] = v

  for k, v in assignments(logStmtBindings):
    finalBindings[k] = v

  finalBindings.sort do (lhs, rhs: auto) -> int: cmp(lhs[0], rhs[0])

  var enabledTopicsMatch = enabledTopics.len == 0
  var requiredTopicsCount = requiredTopics.len
  var currentTopics: seq[string] = @[]

  if finalBindings.hasKey("topics"):
    let topicsNode = finalBindings["topics"].value
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

  var code = newStmtList()
  when runtimeFilteringEnabled:
    code.add runtimeTopicFilteringCode(severity, currentTopics)

  let
    recordTypeSym = skipTypedesc(recordType.getTypeImpl())
    recordTypeNodes = recordTypeSym.getTypeImpl()
    recordArity = if recordTypeNodes.kind != nnkTupleConstr: 1
                  else: recordTypeNodes.len
    record = genSym(nskVar, "record")
    threadId = when compileOption("threads"): newCall("getThreadId")
               else: newLit(0)

  code.add quote do:
    var `record`: `recordType`

  for i in 0 ..< recordArity:
    let recordRef = if recordArity == 1: record
                    else: newTree(nnkBracketExpr, record, newLit(i))
    code.add quote do:
      initLogRecord(`recordRef`, LogLevel(`severity`), `eventName`)
      setFirstProperty(`recordRef`, "thread", `threadId`)

    for k, v in finalBindings:
      code.add newCall("setProperty", recordRef, newLit(k), v.value)

  code.add newCall("logAllDynamicProperties", record)
  code.add newCall("flushRecord", record)

  result = newBlockStmt(id"chroniclesLogStmt", code)

template log*(severity: LogLevel,
              eventName: static[string],
              props: varargs[untyped]) {.dirty.} =

  bind logIMPL, bindSym, brForceOpen
  logIMPL(activeChroniclesStream(), eventName, severity,
          bindSym("activeChroniclesScope", brForceOpen), props)

template log*(recordType: typedesc,
              severity: static[LogLevel],
              eventName: static[string],
              props: varargs[untyped]) {.dirty.} =

  bind logIMPL, bindSym, brForceOpen
  logIMPL(recordType, eventName, severity,
          bindSym("activeChroniclesScope", brForceOpen), props)

template logFn(name, severity) {.dirty.} =
  template `name`*(eventName: static[string],
                   props: varargs[untyped]) {.dirty.} =

    bind logIMPL, bindSym, brForceOpen
    logIMPL(activeChroniclesStream(), eventName, severity,
            bindSym("activeChroniclesScope", brForceOpen), props)

  template `name`*(recordType: typedesc,
                   eventName: static[string],
                   props: varargs[untyped])  {.dirty.} =

    bind logIMPL, bindSym, brForceOpen
    logIMPL(recordType, eventName, severity,
            bindSym("activeChroniclesScope", brForceOpen), props)

logFn debug , LogLevel.DEBUG
logFn info  , LogLevel.INFO
logFn notice, LogLevel.NOTICE
logFn warn  , LogLevel.WARN
logFn error , LogLevel.ERROR
logFn fatal , LogLevel.FATAL

