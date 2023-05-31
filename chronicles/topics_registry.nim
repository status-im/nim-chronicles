import locks, macros, tables
from options import LogLevel

export
  LogLevel

type
  TopicState* = enum
    Normal,
    Enabled,
    Required,
    Disabled

  TopicSettings* = object
    state*: TopicState
    logLevel*: LogLevel

  TopicsRegisty* = object
    topicStatesTable*: Table[string, ptr TopicSettings]

var
  registryLock: Lock
  gActiveLogLevel       {.guard: registryLock.}: LogLevel
  gTotalEnabledTopics   {.guard: registryLock.}: int
  gTotalRequiredTopics  {.guard: registryLock.}: int
  gTopicStates          {.guard: registryLock.} = initTable[string, ptr TopicSettings]()

when compileOption("threads"):
  var mainThreadId = getThreadId()

initLock(registryLock)

template lockRegistry(body: untyped) =
  when compileOption("threads"):
    withLock registryLock: body
  else:
    {.locks: [registryLock].}: body

proc setLogLevel*(lvl: LogLevel) =
  lockRegistry:
    gActiveLogLevel = lvl

proc clearTopicsRegistry* =
  lockRegistry:
    gTotalEnabledTopics = 0
    gTotalRequiredTopics = 0
    for val in gTopicStates.values:
      val.state = Normal

proc registerTopic*(name: string, topic: ptr TopicSettings): ptr TopicSettings =
  # As long as sequences are thread-local, modifying the `gTopicStates`
  # sequence must be done only from the main thread:
  when compileOption("threads"):
    doAssert getThreadId() == mainThreadId

  lockRegistry:
    gTopicStates[name] = topic
    return topic

proc setTopicState*(name: string,
                    newState: TopicState,
                    logLevel = LogLevel.NONE): bool =
  lockRegistry:
    if not gTopicStates.hasKey(name):
      return false

    var topicPtr = gTopicStates[name]

    case topicPtr.state
    of Enabled: dec gTotalEnabledTopics
    of Required: dec gTotalRequiredTopics
    else: discard

    case newState
    of Enabled: inc gTotalEnabledTopics
    of Required: inc gTotalRequiredTopics
    else: discard

    topicPtr.state = newState
    topicPtr.logLevel = logLevel

    return true

proc topicsMatch*(logStmtLevel: LogLevel,
                  logStmtTopics: openArray[ptr TopicSettings]): bool =
  lockRegistry:
    var
      hasEnabledTopics = gTotalEnabledTopics > 0
      enabledTopicsMatch = false
      normalTopicsMatch = logStmtTopics.len == 0 and logStmtLevel >= gActiveLogLevel
      requiredTopicsCount = gTotalRequiredTopics

    for topic in logStmtTopics:
      let topicLogLevel = if topic.logLevel != NONE: topic.logLevel
                          else: gActiveLogLevel
      if logStmtLevel >= topicLogLevel:
        case topic.state
        of Normal: normalTopicsMatch = true
        of Enabled: enabledTopicsMatch = true
        of Disabled: return false
        of Required: normalTopicsMatch = true; dec requiredTopicsCount

    if requiredTopicsCount > 0:
      return false

    if hasEnabledTopics and not enabledTopicsMatch:
      return false

    return normalTopicsMatch

proc getTopicState*(topic: string): ptr TopicSettings =
  lockRegistry:
    return gTopicStates.getOrDefault(topic)

