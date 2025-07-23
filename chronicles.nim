import
  macros, tables, strutils, strformat,
  chronicles/[formats, scope_helpers, dynamic_scope, log_output, options]

export
  formats, dynamic_scope, log_output, options

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

when not defined(nimHasTemplateRedefinitionPragma):
  {.pragma: redefine.}

macro logScopeIMPL(prevScopes: typed,
                   newBindings: untyped,
                   isPublic: static[bool]): untyped =
  result = newStmtList()
  var
    bestScope = prevScopes.lastScopeBody
    bestScopeRev = bestScope.scopeRevision
    newRevision = newLit(bestScopeRev + 1)
    finalBindings = initOrderedTable[string, NimNode]()
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
    template `activeScope` {.used, redefine.} =
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

let chroniclesBlockName {.compileTime.} = ident "chroniclesLogStmt"
let chroniclesTopicsMatchVar {.compileTime.} = ident "chroniclesTopicsMatch"

when runtimeFilteringEnabled:
  import chronicles/topics_registry
  export setTopicState, setLogEnabled, setLogLevel, TopicState

  proc topicStateIMPL(topicName: static[string]): ptr TopicSettings =
    # Nim's GC safety analysis gets confused by the global variables here
    {.gcsafe.}:
      var topic {.global.}: TopicSettings
      var dummy {.global, used.} = registerTopic(topicName, addr(topic))
      return addr(topic)

  proc runtimeTopicFilteringCode*(logLevel: LogLevel, topics: seq[string]): NimNode =
    # This proc generates the run-time code used for topic filtering.
    # Each logging statement has a statically known list of associated topics.
    # For each of the topics in the list, we consult a global TopicState value
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
      let `chroniclesTopicsMatchVar` = `topicsMatch`(LogLevel(`logLevel`), `topicsArray`)
      if `chroniclesTopicsMatchVar` == 0:
        break `chroniclesBlockName`
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

template chroniclesUsedMagic(x: untyped) =
  # Force the compiler to mark any symbol in the x
  # as used without actually generate any code.
  when compiles(x): discard

macro logIMPL(lineInfo: static InstInfo,
              Stream: typed,
              RecordType: type,
              eventName: static[string],
              severity: static[LogLevel],
              scopes: typed,
              logStmtBindings: varargs[untyped]): untyped =
  clearEmptyVarargs logStmtBindings

  # First, we merge the lexical bindings with the additional
  # bindings passed to the logging statement itself:
  let lexicalBindings = scopes.finalLexicalBindings
  var finalBindings = initOrderedTable[string, NimNode]()

  for k, v in assignments(logStmtBindings, acLogStatement):
    finalBindings[k] = v

  for k, v in assignments(lexicalBindings, acLogStatement):
    finalBindings[k] = v

  result = newStmtList()

  if not loggingEnabled:
    # This statement is to silence compiler warnings
    # `declared but not used` when there is no logging code generated.
    # push/pop pragma pairs cannot be used in this situation
    # because the variables are declared outside of this function.
    result.add quote do: chroniclesUsedMagic(`eventName`)
    for k, v in finalBindings:
      result.add quote do: chroniclesUsedMagic(`v`)

    return

  # This is the compile-time topic filtering code, which has a similar
  # logic to the generated run-time filtering code:
  var enabledTopicsMatch = enabledTopics.len == 0 and severity >= enabledLogLevel
  var requiredTopicsCount = requiredTopics.len
  var topicsNode = newLit("")
  var activeTopics: seq[string] = @[]
  var useLineNumbers = lineNumbersEnabled
  var useThreadIds = threadIdsEnabled
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
            if topic.logLevel != LogLevel.NONE:
              if severity >= topic.logLevel:
                enabledTopicsMatch = true
            elif severity >= enabledLogLevel:
              enabledTopicsMatch = true
        if t in requiredTopics:
          dec requiredTopicsCount

  if severity != NONE and not enabledTopicsMatch or requiredTopicsCount > 0:
    return

  proc lookForScopeOverride(option: var bool, overrideName: string) =
    if finalBindings.hasKey(overrideName):
      let overrideValue = $finalBindings[overrideName]
      if overrideValue notin ["true", "false"]:
        error(overrideName & " should be set to either true or false",
              finalBindings[overrideName])
      option = overrideValue == "true"
      finalBindings.del(overrideName)

  # The user is allowed to override the compile-time options for line numbers
  # and thread ids in particular log statements or scopes:
  lookForScopeOverride(useLineNumbers, "chroniclesLineNumbers")
  lookForScopeOverride(useThreadIds, "chroniclesThreadIds")

  var code = newStmtList()

  when runtimeFilteringEnabled:
    if severity != LogLevel.NONE:
      code.add runtimeTopicFilteringCode(severity, activeTopics)

  # The rest of the code selects the active LogRecord type (which can
  # be a tuple when the sink has multiple destinations) and then
  # translates the log statement to a set of calls to `initLogRecord`,
  # `setProperty` and `flushRecord`.
  let
    record = genSym(nskVar, "record")
    recordTypeSym = skipTypedesc(RecordType.getTypeImpl())
    recordTypeNodes = recordTypeSym.getTypeImpl()
    recordArity = if recordTypeNodes.kind != nnkTupleConstr: 1
                  else: recordTypeNodes.len
    lvl = newDotExpr(bindSym("LogLevel", brClosed), ident $severity)
    chroniclesExpandItIMPL = bindSym("chroniclesExpandItIMPL", brForceOpen)
    prepareOutput = bindSym("prepareOutput", brForceOpen)
    initLogRecord = bindSym("initLogRecord", brForceOpen)
    setProperty = bindSym("setProperty", brForceOpen)

  code.add quote do:
    var `record`: `RecordType`

  if recordArity > 1 and runtimeFilteringEnabled:
    code.add quote do:
      `prepareOutput`(`record`, `lvl`, `chroniclesTopicsMatchVar`)
      `initLogRecord`(`record`, `lvl`, `topicsNode`, `eventName`, `chroniclesTopicsMatchVar`)
  else:
    code.add quote do:
      `prepareOutput`(`record`, `lvl`)
      `initLogRecord`(`record`, `lvl`, `topicsNode`, `eventName`)

  if useThreadIds:
    # called tid even when it's a process id - this to avoid differences in
    # logging between threads and no threads
    if recordArity > 1 and runtimeFilteringEnabled:
      code.add quote do:
        `setProperty`(`record`, "tid", getLogThreadId(), `chroniclesTopicsMatchVar`)
    else:
      code.add quote do:
        `setProperty`(`record`, "tid", getLogThreadId())

  if useLineNumbers:
    var filename = lineInfo.filename & ":" & $lineInfo.line
    if recordArity > 1 and runtimeFilteringEnabled:
      code.add newCall(setProperty, record, newLit("file"), newLit(filename), chroniclesTopicsMatchVar)
    else:
      code.add newCall(setProperty, record, newLit("file"), newLit(filename))

  for k, v in finalBindings:
    if recordArity > 1 and runtimeFilteringEnabled:
      code.add newCall(chroniclesExpandItIMPL, record, newLit(k), v, chroniclesTopicsMatchVar)
    else:
      code.add newCall(chroniclesExpandItIMPL, record, newLit(k), v)

  if recordArity > 1 and runtimeFilteringEnabled:
    code.add newCall("logAllDynamicProperties", Stream, record, chroniclesTopicsMatchVar)
    code.add newCall("flushRecord", record, chroniclesTopicsMatchVar)
  else:
    code.add newCall("logAllDynamicProperties", Stream, record)
    code.add newCall("flushRecord", record)

  result.add quote do:
    try:
      block `chroniclesBlockName`:
        `code`
    except CatchableError as err:
      logLoggingFailure(cstring(`eventName`), err)

  when defined(debugLogImpl):
    echo result.repr

# Translate all the possible overloads to `logIMPL`:
template log*(lineInfo: static InstInfo,
              severity: static[LogLevel],
              eventName: static[string],
              props: varargs[untyped]) {.dirty.} =

  bind logIMPL, bindSym, brForceOpen
  logIMPL(lineInfo, activeChroniclesStream(),
          Record(activeChroniclesStream()), eventName, severity,
          bindSym("activeChroniclesScope", brForceOpen), props)

template log*(lineInfo: static InstInfo,
              stream: type,
              severity: static[LogLevel],
              eventName: static[string],
              props: varargs[untyped]) {.dirty.} =

  bind logIMPL, bindSym, brForceOpen
  logIMPL(lineInfo, stream, stream.Record, eventName, severity,
          bindSym("activeChroniclesScope", brForceOpen), props)

template wrapSideEffects(debug: bool, body: untyped) {.inject.} =
  when debug:
    {.noSideEffect.}:
      when defined(nimHasWarnBareExcept):
        {.push warning[BareExcept]:off.}
      try: body
      except: discard
      when defined(nimHasWarnBareExcept):
        {.pop.}
  else:
    body

template logFn(name: untyped, severity: typed, debug=false) {.dirty.} =
  bind log, wrapSideEffects

  template `name`*(eventName: static[string], props: varargs[untyped]) {.dirty.} =
    wrapSideEffects(debug):
      log(instantiationInfo(), severity, eventName, props)

  template `name`*(stream: type, eventName: static[string], props: varargs[untyped]) {.dirty.} =
    wrapSideEffects(debug):
      log(instantiationInfo(), stream, severity, eventName, props)

logFn trace , LogLevel.TRACE, debug=true
logFn debug , LogLevel.DEBUG
logFn info  , LogLevel.INFO
logFn notice, LogLevel.NOTICE
logFn warn  , LogLevel.WARN
logFn error , LogLevel.ERROR
logFn fatal , LogLevel.FATAL

# TODO:
#
# * extract the compile-time conf framework in confutils
# * instance carried streams that can collect the information in memory
#
# * define an alternative format strings API (.net style)
# * auto-derived topics based on nimble package name and module name
#
# * Android and iOS logging, mixed std streams (logging both to stdout and stderr?)
# * dynamic scope overrides (plus maybe an option to control the priority
#                            between dynamic and lexical bindings)
#
# * implement some of the leading standardized structured logging formats

