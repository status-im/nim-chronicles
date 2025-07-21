{.push raises: [].}

import std/[locks, tables], stew/shims/macros

from options import config, LogLevel, runtimeFilteringEnabled

export LogLevel

const totalSinks* = block:
  var total = 0
  for stream in config.streams:
    for sink in stream.sinks:
      inc total
  when runtimeFilteringEnabled:
    # SinksBitmask limit
    doAssert total <= 8, "Cannot have more than 8 sinks"
  total

type
  TopicState* = enum
    Normal
    Enabled
    Required
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

  SinksBitmask* = uint8

var
  registryLock: Lock
  runtimeConfig {.guard: registryLock.}: RuntimeConfig
  gTopicStates {.guard: registryLock.}: Table[string, ptr TopicSettings]

when compileOption("threads"):
  var mainThreadId = getThreadId()

initLock(registryLock)

template lockRegistry(body: untyped) =
  when compileOption("threads"):
    withLock registryLock:
      body
  else:
    {.locks: [registryLock].}:
      body

proc setLogLevel*(lvl: LogLevel) =
  lockRegistry:
    for sink in mitems(runtimeConfig.sinkStates):
      sink.activeLogLevel = lvl

proc setLogLevel*(lvl: LogLevel, sinkIdx: int) =
  lockRegistry:
    if sinkIdx < runtimeConfig.sinkStates.len:
      runtimeConfig.sinkStates[sinkIdx].activeLogLevel = lvl

# Used only in chronicles-tail
proc clearTopicsRegistry*() =
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

  topic

proc setTopicState*(
    name: string, sinkIdx: int, newState: TopicState, logLevel = LogLevel.NONE
): bool {.raises: [].} =
  if sinkIdx >= totalSinks:
    return false

  lockRegistry:
    gTopicStates.withValue(name, topicPtr):
      template sinkState(): auto =
        runtimeConfig.sinkStates[sinkIdx]

      template topicState(): auto =
        topicPtr[][][sinkIdx]

      case topicState.state
      of Enabled:
        dec sinkState.totalEnabledTopics
      of Required:
        dec sinkState.totalRequiredTopics
      else:
        discard

      case newState
      of Enabled:
        inc sinkState.totalEnabledTopics
      of Required:
        inc sinkState.totalRequiredTopics
      else:
        discard

      topicState.state = newState
      topicState.logLevel = logLevel

      return true
    do:
      return false

proc setTopicState*(
    name: string, newState: TopicState, logLevel = LogLevel.NONE
): bool =
  result = true
  for sinkIdx in 0 ..< totalSinks:
    result = result and setTopicState(name, sinkIdx, newState, logLevel)

proc setBit(x: var SinksBitmask, bitIdx: int, bitValue: bool) =
  x = x or (SinksBitmask(bitValue) shl bitIdx)

proc topicsMatch*(
    logStmtLevel: LogLevel, logStmtTopics: openArray[ptr TopicSettings],
): SinksBitmask =
  lockRegistry:
    for sinkIdx {.inject.} in 0 ..< totalSinks:
      template sinkState(): auto =
        runtimeConfig.sinkStates[sinkIdx]

      var
        hasEnabledTopics = sinkState.totalEnabledTopics > 0
        enabledTopicsMatch = false
        disabled = false
        normalTopicsMatch = logStmtTopics.len == 0 and  logStmtLevel >= sinkState.activeLogLevel
        requiredTopicsCount = sinkState.totalRequiredTopics

      for topic in logStmtTopics:
        template topicState(): auto =
          topic[][sinkIdx]

        let topicLogLevel =
          if topicState.logLevel != LogLevel.NONE:
            topicState.logLevel
          else:
            sinkState.activeLogLevel

        if logStmtLevel >= topicLogLevel:
          case topicState.state
          of Normal:
            normalTopicsMatch = true
          of Enabled:
            enabledTopicsMatch = true
          of Disabled:
            disabled = true
            break
          of Required:
            normalTopicsMatch = true
            dec requiredTopicsCount

      if requiredTopicsCount > 0 or disabled:
        continue

      if hasEnabledTopics and not enabledTopicsMatch:
        continue

      result.setBit(sinkIdx, normalTopicsMatch)

proc getTopicState*(topic: string): ptr TopicSettings =
  lockRegistry:
    return gTopicStates.getOrDefault(topic)
