import locks, macros, tables
from options import LogLevel

type
  TopicState* = enum
    Normal,
    Enabled,
    Required,
    Disabled

  Topic* = object
    state*: TopicState
    logLevel*: LogLevel

  TopicsRegistry* = object
    totalEnabledTopics*: int
    totalRequiredTopics*: int
    topicStatesTable*: Table[string, Topic]

template lock(someLock: Lock, body: untyped) =
  {.locks: [someLock].}:
    when compileOption("threads"):
      someLock.acquire()
      try:
        body
      finally:
        someLock.release()
    else:
      body

var
  gActiveLogLevelLock: Lock
  gActiveLogLevel {.guard: gActiveLogLevelLock.}: LogLevel
initLock(gActiveLogLevelLock)

template lockGActiveLogLevel(body: untyped) =
  lock(gActiveLogLevelLock, body)

proc setLogLevel*(lvl: LogLevel) =
  lockGActiveLogLevel:
    gActiveLogLevel = lvl

var
  registryLock: Lock
  registry {.guard: registryLock.}: TopicsRegistry
initLock(registryLock)
registry.topicStatesTable = initTable[string, Topic]()

# don't `return` from the body, or the lock won't be released
template lockRegistry(body: untyped) =
  {.gcsafe.}: # this will, of course, break if https://github.com/nim-lang/RFCs/issues/142 is implemented
    lock(registryLock, body)

proc clearTopicsRegistry* =
  lockRegistry:
    registry.totalEnabledTopics = 0
    registry.totalRequiredTopics = 0
    registry.topicStatesTable.clear()

proc registerTopic*(name: string, topic: Topic) =
  lockRegistry:
    registry.topicStatesTable[name] = topic

proc setTopicState*(name: string, newState: TopicState, logLevel = LogLevel.NONE): bool =
  result = true
  lockRegistry:
    block registryBlock: # for early exits without bypassing the lock release
      if not registry.topicStatesTable.hasKey(name):
        result = false
        break

      var topic = registry.topicStatesTable[name]

      case topic.state
      of Enabled: dec registry.totalEnabledTopics
      of Required: dec registry.totalRequiredTopics
      else: discard

      case newState
      of Enabled: inc registry.totalEnabledTopics
      of Required: inc registry.totalRequiredTopics
      else: discard

      topic.state = newState
      topic.logLevel = logLevel
      registry.topicStatesTable[name] = topic

proc topicsMatch*(logStmtLevel: LogLevel, logStmtTopics: openarray[Topic]): bool =
  lockRegistry:
    block registryBlock:
      var
        hasEnabledTopics = registry.totalEnabledTopics > 0
        enabledTopicsMatch = false
        normalTopicsMatch: bool
        requiredTopicsCount = registry.totalRequiredTopics

      lockGActiveLogLevel:
        normalTopicsMatch = logStmtTopics.len == 0 and logStmtLevel >= gActiveLogLevel

      for topic in logStmtTopics:
        var topicLogLevel: LogLevel
        lockGActiveLogLevel:
          topicLogLevel = if topic.logLevel != NONE: topic.logLevel else: gActiveLogLevel
        if logStmtLevel >= topicLogLevel:
          case topic.state
          of Normal:
            normalTopicsMatch = true
          of Enabled:
            enabledTopicsMatch = true
          of Disabled:
            result = false
            break
          of Required:
            dec requiredTopicsCount

      if requiredTopicsCount > 0:
        result = false
        break

      if hasEnabledTopics and not enabledTopicsMatch:
        result = false
        break

      result = normalTopicsMatch

proc getTopicState*(topicName: string): Topic =
  lockRegistry:
    result = registry.topicStatesTable[topicName]

