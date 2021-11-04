import locks, macros, tables
from options import config, LogLevel

export
  LogLevel

const totalSinks* = block:
  var total = 0
  for stream in config.streams:
    for sink in stream.sinks:
      inc total
  total

type
  TopicState* = enum
    Normal,
    Enabled,
    Required,
    Disabled

  SinkTopicSettings* = object
    state*: TopicState
    logLevel*: LogLevel

  TopicSettings* = array[totalSinks, SinkTopicSettings]

  SinkFilteringState = object
    activeLogLevel: LogLevel
    totalEnabledTopics: int
    totalRequiredTopics: int

  RuntimeConfig* = object
    sinkStates: array[totalSinks, SinkFilteringState]

  SinksBitmask = uint8

var
  registryLock: Lock
  runtimeConfig {.guard: registryLock.}: RuntimeConfig
  gTopicStates {.guard: registryLock.}: Table[string, ptr TopicSettings]

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
    for sink in mitems(runtimeConfig.sinkStates):
      sink.activeLogLevel = lvl

# Used only in chronicles-tail
proc clearTopicsRegistry* =
  lockRegistry:
    for sink in mitems(runtimeConfig.sinkStates):
      sink.totalEnabledTopics = 0
      sink.totalRequiredTopics = 0

    for name, topicSinksSettings in mpairs(gTopicStates):
      for topic in mitems(topicSinksSettings[]):
        topic.state = Normal

proc registerTopic*(name: string, topic: ptr TopicSettings): ptr TopicSettings =
  # As long as sequences are thread-local, modifying the `gTopicStates`
  # sequence must be done only from the main thread:
  when compileOption("threads"):
    doAssert getThreadId() == mainThreadId

  lockRegistry:
    gTopicStates[name] = topic

  return topic

proc setTopicState*(name: string,
                    sinkIdx: int,
                    newState: TopicState,
                    logLevel = LogLevel.DEFAULT): bool =
  if sinkIdx >= totalSinks:
    return false

  lockRegistry:
    if not gTopicStates.hasKey(name):
      return false

    template sinkState: auto =
      runtimeConfig.sinkStates[sinkIdx]

    var topicPtr = gTopicStates[name][sinkIdx]

    case topicPtr.state
    of Enabled: dec sinkState.totalEnabledTopics
    of Required: dec sinkState.totalRequiredTopics
    else: discard

    case newState
    of Enabled: inc sinkState.totalEnabledTopics
    of Required: inc sinkState.totalRequiredTopics
    else: discard

    topicPtr.state = newState
    topicPtr.logLevel = logLevel

    return true

proc setTopicState*(name: string,
                    newState: TopicState,
                    logLevel = LogLevel.DEFAULT): bool =
  result = true
  for sinkIdx in 0 ..< totalSinks:
    result = result and setTopicState(name, sinkIdx, newState, logLevel)

proc setBit(x: var SinksBitmask, bitIdx: int, bitValue: bool) =
  x = x or (SinksBitmask(bitValue) shl bitIdx)

proc topicsMatch*(logStmtLevel: LogLevel,
                  logStmtTopics: openarray[ptr TopicSettings]): SinksBitmask {.gcsafe.} =
  lockRegistry:
    for sinkIdx {.inject.} in 0 ..< totalSinks:
      template sinkState: auto = runtimeConfig.sinkStates[sinkIdx]

      if logStmtLevel < sinkState.activeLogLevel:
        continue

      var
        hasEnabledTopics = sinkState.totalEnabledTopics > 0
        enabledTopicsMatch = false
        normalTopicsMatch = logStmtTopics.len == 0
        requiredTopicsCount = sinkState.totalRequiredTopics

      for topic in logStmtTopics:
        template topicState: auto = topic[][sinkIdx]
        let topicLogLevel = if topicState.logLevel != DEFAULT: topicState.logLevel
                            else: sinkState.activeLogLevel
        if logStmtLevel >= topicLogLevel:
          case topicState.state
          of Normal: normalTopicsMatch = true
          of Enabled: enabledTopicsMatch = true
          of Disabled: continue
          of Required: normalTopicsMatch = true; dec requiredTopicsCount

      if requiredTopicsCount > 0:
        continue

      if hasEnabledTopics and not enabledTopicsMatch:
        continue

      result.setBit(sinkIdx, normalTopicsMatch)

proc getTopicState*(topic: string): ptr TopicSettings =
  lockRegistry:
    return gTopicStates.getOrDefault(topic)

