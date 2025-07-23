{.push raises: [].}

import std/[atomics, locks, tables], stew/shims/macros

from options import config, LogLevel, runtimeFilteringEnabled

export atomics, LogLevel

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
    state: Atomic[TopicState]
    logLevel: Atomic[LogLevel]

  TopicSettings* = array[totalSinks, SinkTopicSettings]

  SinkFilteringState = object
    disabled: Atomic[bool]
      ## `disabled = false` by default which matches the compile-time
      ## `chronicles_enabled = true` configuration - messy with the opposites
      ## but plays better with runtime defaults
    activeLogLevel: Atomic[LogLevel]
    totalEnabledTopics: Atomic[int]
    totalRequiredTopics: Atomic[int]

  RuntimeConfig* = object
    sinkStates: array[totalSinks, SinkFilteringState]

  SinksBitmask* = uint8

# moRelaxed is safe since there is no need to coordinate topic state updates
# between threads other than ensuring the counting is correct / atomic

template state*(s: SinkTopicSettings): TopicState =
  # TODO https://github.com/nim-lang/Nim/pull/23767
  let tmp = addr s.state
  tmp[].load(moRelaxed)

template `state=`*(s: var SinkTopicSettings, v: TopicState) =
  s.state.store(v, moRelaxed)

template logLevel*(s: SinkTopicSettings): LogLevel =
  # TODO https://github.com/nim-lang/Nim/pull/23767
  let tmp = addr s.logLevel
  tmp[].load(moRelaxed)

template `logLevel=`*(s: var SinkTopicSettings, v: LogLevel) =
  s.logLevel.store(v, moRelaxed)

var
  registryLock: Lock
  runtimeConfig: RuntimeConfig
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

proc setLogEnabled*(enabled: bool) =
  for sink in mitems(runtimeConfig.sinkStates):
    sink.disabled.store(not enabled)

proc setLogEnabled*(enabled: bool, sinkIdx: int) =
  if sinkIdx < runtimeConfig.sinkStates.len:
    runtimeConfig.sinkStates[sinkIdx].disabled.store(not enabled)

proc setLogLevel*(lvl: LogLevel) =
  for sink in mitems(runtimeConfig.sinkStates):
    sink.activeLogLevel.store(lvl)

proc setLogLevel*(lvl: LogLevel, sinkIdx: int) =
  if sinkIdx < runtimeConfig.sinkStates.len:
    runtimeConfig.sinkStates[sinkIdx].activeLogLevel.store(lvl)

# Used only in chronicles-tail
proc clearTopicsRegistry*() =
  lockRegistry:
    for sink in mitems(runtimeConfig.sinkStates):
      sink.totalEnabledTopics.store(0)
      sink.totalRequiredTopics.store(0)

    for name, topicSinksSettings in mpairs(gTopicStates):
      for topic in mitems(topicSinksSettings[]):
        topic.state.store(Normal)

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
): bool =
  if sinkIdx >= totalSinks:
    return false

  lockRegistry:
    gTopicStates.withValue(name, topicPtr):
      template sinkState(): auto =
        runtimeConfig.sinkStates[sinkIdx]

      template topicState(): auto =
        topicPtr[][][sinkIdx]

      let oldState = topicState.state.load(moRelaxed)

      if oldState != newState:
        case oldState
        of Enabled:
          sinkState.totalEnabledTopics -= 1
        of Required:
          sinkState.totalRequiredTopics -= 1
        else:
          discard

        case newState
        of Enabled:
          sinkState.totalEnabledTopics += 1
        of Required:
          sinkState.totalRequiredTopics += 1
        else:
          discard

        topicState.state.store(newState)
      topicState.logLevel.store(logLevel)

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
    logStmtLevel: LogLevel, logStmtTopics: openArray[ptr TopicSettings]
): SinksBitmask =
  for sinkIdx {.inject.} in 0 ..< totalSinks:
    template sinkState(): auto =
      runtimeConfig.sinkStates[sinkIdx]

    if sinkState.disabled.load(moRelaxed):
      continue

    let
      hasEnabledTopics = sinkState.totalEnabledTopics.load(moRelaxed) > 0
      activeLogLevel = sinkState.activeLogLevel.load(moRelaxed)

    var
      enabledTopicsMatch = false
      disabled = false
      normalTopicsMatch = logStmtTopics.len == 0 and logStmtLevel >= activeLogLevel
      requiredTopicsCount = sinkState.totalRequiredTopics.load(moRelaxed)

    for topic in logStmtTopics:
      template topicState(): auto =
        topic[][sinkIdx]

      let
        topicStateLevel = topicState.logLevel.load(moRelaxed)
        topicLogLevel =
          if topicStateLevel != LogLevel.NONE: topicStateLevel else: activeLogLevel

      if logStmtLevel >= topicLogLevel:
        case topicState.state.load(moRelaxed)
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
