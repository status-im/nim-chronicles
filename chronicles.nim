import
  macros, tables, strutils, strformat,
  chronicles/[scope_helpers, dynamic_scope, log_output, options]

export
  dynamic_scope, log_output, options

# So, how does Chronicles work?
#
# The tricky part is understanding how the lexical scopes are implemened.
# For them to work, we need to be able to associate a mutable compile-time
# data with a lexical scope (with a different value for each scope).
# The regular compile-time variable are not suited for this, because they
# offer us only a single global value that can be mutated.
#
# Luckily, we can use the body of a template as the storage mechanism for
# our data. This works, because template names bound to particular scopes
# and templates can be freely redefined as many times as necessary.
#
# `activeChroniclesScope` stores the current lexical scope.
#
# `logScopeIMPL` is used to merge a previously defined scope with some
# new definition in order to produce a new scope:
#

template activeChroniclesScope* =
  0 # track the scope revision

macro logScopeIMPL(prevScopes: typed,
                   newBindings: untyped,
                   isPublic: static[bool]): untyped =
  result = newStmtList()
  var
    bestScope = prevScopes.lastScopeBody
    bestScopeRev = bestScope.scopeRevision
    newRevision = newLit(bestScopeRev + 1)
    finalBindings = initTable[string, NimNode]()
    newAssingments = newStmtList()
    chroniclesExportNode: NimNode = if not isPublic: nil
                                    else: newTree(nnkExportExceptStmt,
                                                  id"chronicles",
                                                  id"activeChroniclesScope")

  for k, v in assignments(bestScope.scopeAssignments, acScopeBlock):
    finalBindings[k] = v

  for k, v in assignments(newBindings, acScopeBlock):
    finalBindings[k] = v

  for k, v in finalBindings:
    if k == "stream":
      let streamId = id($v)
      let errorMsg = &"{v.lineInfo}: {$streamId} is not a recognized stream name"
      let templateName = id("activeChroniclesStream", isPublic)

      result.add quote do:
        when not declared(`streamId`):
          # XXX: how to report the proper line info here?
          {.error: `errorMsg`.}
        #elif not isStreamSymbolIMPL(`streamId`):
        #  {.error: `errorMsg`.}
        template `templateName`: type = `streamId`

      if isPublic:
        chroniclesExportNode.add id"activeChroniclesStream"

    else:
      newAssingments.add newAssignment(id(k), v)

  if isPublic:
    result.add chroniclesExportNode

  let activeScope = id("activeChroniclesScope", isPublic)
  result.add quote do:
    template `activeScope` =
      `newRevision`
      `newAssingments`

template logScope*(newBindings: untyped) {.dirty.} =
  bind bindSym, logScopeIMPL, brForceOpen
  logScopeIMPL(bindSym("activeChroniclesScope", brForceOpen),
               newBindings, false)

template publicLogScope*(newBindings: untyped) {.dirty.} =
  bind bindSym, logScopeIMPL, brForceOpen
  logScopeIMPL(bindSym("activeChroniclesScope", brForceOpen),
               newBindings, true)

template dynamicLogScope*(stream: type,
                          bindings: varargs[untyped]) {.dirty.} =
  bind bindSym, brForceOpen
  dynamicLogScopeIMPL(stream,
                      bindSym("activeChroniclesScope", brForceOpen),
                      bindings)

template dynamicLogScope*(bindings: varargs[untyped]) {.dirty.} =
  bind bindSym, brForceOpen
  dynamicLogScopeIMPL(activeChroniclesStream(),
                      bindSym("activeChroniclesScope", brForceOpen),
                      bindings)

when runtimeFilteringEnabled:
  import chronicles/topics_registry
  export setTopicState, setLogLevel, TopicState

  proc topicStateIMPL(topicName: static[string]): ptr Topic =
    var topic {.global.}: Topic = Topic(state: Normal, logLevel: NONE)
    var dummy {.global.} = registerTopic(topicName, addr(topic))
    return addr(topic)

  proc runtimeTopicFilteringCode*(logLevel: LogLevel, topics: seq[string]): NimNode =
    # This proc generates the run-time code used for topic filtering.
    # Each logging statement has a statically known list of associated topics.
    # For each of the topics in the list, we consult a TLS TopicState value
    # created in topicStateIMPL. `break chroniclesLogStmt` exits a named
    # block surrounding the entire log statement.
    result = newStmtList()
    var
      topicStateIMPL = bindSym("topicStateIMPL")
      topicsMatch = bindSym("topicsMatch")

    var topicsArray = newTree(nnkBracket)
    for topic in topics:
      topicsArray.add newCall(topicStateIMPL, newLit(topic))

    result.add quote do:
      if not `topicsMatch`(LogLevel(`logLevel`), `topicsArray`):
        break chroniclesLogStmt
else:
  template runtimeFilteringDisabledError =
    {.error: "Run-time topic filtering is currently disabled. " &
             "You can enable it by specifying '-d:chronicles_runtime_filtering:on'".}

  template setTopicState*(name, state) = runtimeFilteringDisabledError
  template setLogLevel*(name, state) = runtimeFilteringDisabledError

type InstInfo = tuple[filename: string, line: int, column: int]

when compileOption("threads"):
  # With threads turned on, we give the thread id
  # TODO: Does this make sense on all platforms? On linux, conveniently, the
  #       process id is the thread id of the `main` thread..
  proc getLogThreadId*(): int = getThreadId()
else:
  # When there are no threads, we show the process id instead, allowing easy
  # correlation on multiprocess systems
  when defined(posix):
    import posix
    proc getLogThreadId*(): int = int(posix.getpid())
  elif defined(windows):
    proc getCurrentProcessId(): uint32 {.
      stdcall, dynlib: "kernel32", importc: "GetCurrentProcessId".}
    proc getLogThreadId*(): int = int(getCurrentProcessId())
  else:
    proc getLogThreadId*(): int = 0

macro logIMPL(lineInfo: static InstInfo,
              Stream: typed,
              RecordType: type,
              eventName: static[string],
              severity: static[LogLevel],
              scopes: typed,
              logStmtBindings: varargs[untyped]): untyped =
  if not loggingEnabled: return
  clearEmptyVarargs logStmtBindings

  # First, we merge the lexical bindings with the additional
  # bindings passed to the logging statement itself:
  let lexicalBindings = scopes.finalLexicalBindings
  var finalBindings = initOrderedTable[string, NimNode]()

  for k, v in assignments(lexicalBindings, acLogStatement):
    finalBindings[k] = v

  for k, v in assignments(logStmtBindings, acLogStatement):
    finalBindings[k] = v

  finalBindings.sort do (lhs, rhs: auto) -> int: cmp(lhs[0], rhs[0])

  # This is the compile-time topic filtering code, which has a similar
  # logic to the generated run-time filtering code:
  var enabledTopicsMatch = enabledTopics.len == 0 and severity >= enabledLogLevel
  var requiredTopicsCount = requiredTopics.len
  var topicsNode = newLit("")
  var activeTopics: seq[string] = @[]
  var useLineNumbers = lineNumbersEnabled

  if finalBindings.hasKey("topics"):
    topicsNode = finalBindings["topics"]
    finalBindings.del("topics")

    if topicsNode.kind notin {nnkStrLit, nnkTripleStrLit}:
      error "Please specify the 'topics' list as a space separated string literal", topicsNode

    activeTopics = topicsNode.strVal.split({','} + Whitespace)

    for t in activeTopics:
      if t in disabledTopics:
        return
      else:
        for topic in enabledTopics:
          if topic.name == t:
            if topic.logLevel != NONE:
              if severity >= topic.logLevel:
                enabledTopicsMatch = true
            elif severity >= enabledLogLevel:
              enabledTopicsMatch = true
        if t in requiredTopics:
          dec requiredTopicsCount

  if severity != NONE and not enabledTopicsMatch or requiredTopicsCount > 0:
    return

  # Handling file name and line numbers on/off (lineNumbersEnabled) for particular log statements
  if finalBindings.hasKey("chroniclesLineNumbers"):
    let chroniclesLineNumbers = $finalBindings["chroniclesLineNumbers"]
    if chroniclesLineNumbers notin ["true", "false"]:
      error("chroniclesLineNumbers should be set to either true or false",
            finalBindings["chroniclesLineNumbers"])
    useLineNumbers = chroniclesLineNumbers == "true"
    finalBindings.del("chroniclesLineNumbers")

  var code = newStmtList()
  when runtimeFilteringEnabled:
    if severity != NONE:
      code.add runtimeTopicFilteringCode(severity, activeTopics)

  # The rest of the code selects the active LogRecord type (which can
  # be a tuple when the sink has multiple destinations) and then
  # translates the log statement to a set of calls to `initLogRecord`,
  # `setProperty` and `flushRecord`.
  let
    recordTypeSym = skipTypedesc(RecordType.getTypeImpl())
    recordTypeNodes = recordTypeSym.getTypeImpl()
    recordArity = if recordTypeNodes.kind != nnkTupleConstr: 1
                  else: recordTypeNodes.len
    record = genSym(nskVar, "record")

  code.add quote do:
    var `record`: `RecordType`
    prepareOutput(`record`, LogLevel(`severity`))
    initLogRecord(`record`, LogLevel(`severity`), `topicsNode`, `eventName`)
    # called tid even when it's a process id - this to avoid differences in
    # logging between threads and no threads
    setFirstProperty(`record`, "tid", getLogThreadId())

  if useLineNumbers:
    var filename = lineInfo.filename & ":" & $lineInfo.line
    code.add newCall("setProperty", record,
                     newLit("file"), newLit(filename))

  for k, v in finalBindings:
    code.add newCall("setProperty", record, newLit(k), v)

  code.add newCall("logAllDynamicProperties", Stream, record)
  code.add newCall("flushRecord", record)

  result = newBlockStmt(id"chroniclesLogStmt", code)

  when defined(debugLogImpl):
    echo result.repr

# Translate all the possible overloads to `logIMPL`:
template log*(severity: static[LogLevel],
              eventName: static[string],
              props: varargs[untyped]) {.dirty.} =

  bind logIMPL, bindSym, brForceOpen
  logIMPL(instantiationInfo(), activeChroniclesStream(),
          activeChroniclesStream().Record, eventName, severity,
          bindSym("activeChroniclesScope", brForceOpen), props)

template log*(stream: type,
              severity: static[LogLevel],
              eventName: static[string],
              props: varargs[untyped]) {.dirty.} =

  bind logIMPL, bindSym, brForceOpen
  logIMPL(instantiationInfo(), stream, stream.Record, eventName, severity,
          bindSym("activeChroniclesScope", brForceOpen), props)

template logFn(name, severity) {.dirty.} =
  template `name`*(eventName: static[string],
                   props: varargs[untyped]) {.dirty.} =

    bind logIMPL, bindSym, brForceOpen
    logIMPL(instantiationInfo(), activeChroniclesStream(),
            activeChroniclesStream().Record, eventName, severity,
            bindSym("activeChroniclesScope", brForceOpen), props)

  template `name`*(stream: type,
                   eventName: static[string],
                   props: varargs[untyped])  {.dirty.} =

    bind logIMPL, bindSym, brForceOpen
    logIMPL(instantiationInfo(), stream, stream.Record, eventName, severity,
            bindSym("activeChroniclesScope", brForceOpen), props)

logFn trace , LogLevel.TRACE
logFn debug , LogLevel.DEBUG
logFn info  , LogLevel.INFO
logFn notice, LogLevel.NOTICE
logFn warn  , LogLevel.WARN
logFn error , LogLevel.ERROR
logFn fatal , LogLevel.FATAL

# TODO:
#
# * dynamic sinks
# * Android and iOS logging, mixed std streams (logging both to stdout and stderr?)
# * evaluate the lexical expressions only once in the presence of multiple sinks
# * dynamic scope overrides (plus maybe an option to control the priority
#                            between dynamic and lexical bindings)
# * custom streams must be able to affect third party libraries
#   (perhaps they should work as Chronicles plugins)
#
