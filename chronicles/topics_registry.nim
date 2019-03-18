import macros, tables
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
    topicStatesTable*: TableRef[string, Topic]

var gActiveLogLevel: LogLevel

proc setLogLevel*(lvl: LogLevel) =
  gActiveLogLevel = lvl

var topicsRegistry {.threadvar.}: ref TopicsRegistry

proc getTopicsRegistry*(): ref TopicsRegistry =
  # "topicsRegistry" needs to be initialised in each thread.
  # Since we don't know which procedures are going to deal with an uninitialised
  # threadvar, we're having them all access it through this getter.
  if topicsRegistry.isNil():
    topicsRegistry = new TopicsRegistry
  if topicsRegistry.topicStatesTable.isNil():
    topicsRegistry.topicStatesTable = newTable[string, Topic]()
  return topicsRegistry

proc clearTopicsRegistry* =
  var registry = getTopicsRegistry()
  registry.totalEnabledTopics = 0
  registry.totalRequiredTopics = 0
  for val in registry.topicStatesTable.mvalues():
    val.state = Normal

iterator topicStates*: (string, TopicState) =
  var registry = getTopicsRegistry()
  for name, topic in registry.topicStatesTable:
    yield (name, topic.state)

proc registerTopic*(name: string, topic: Topic) =
  var registry = getTopicsRegistry()
  registry.topicStatesTable[name] = topic

proc setTopicState*(name: string,
                    newState: TopicState,
                    logLevel = LogLevel.NONE): bool =
  var registry = getTopicsRegistry()
  if not registry.topicStatesTable.hasKey(name):
    return false

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

  return true

proc topicsMatch*(logStmtLevel: LogLevel,
                  logStmtTopics: openarray[Topic]): bool =
  var
    registry = getTopicsRegistry()
    hasEnabledTopics = registry.totalEnabledTopics > 0
    enabledTopicsMatch = false
    normalTopicsMatch = logStmtTopics.len == 0
    requiredTopicsCount = registry.totalRequiredTopics

  for topic in logStmtTopics:
    let topicLogLevel = if topic.logLevel != NONE: topic.logLevel
                        else: gActiveLogLevel
    if logStmtLevel >= topicLogLevel:
      case topic.state
      of Normal: normalTopicsMatch = true
      of Enabled: enabledTopicsMatch = true
      of Disabled: return false
      of Required: dec requiredTopicsCount

  if requiredTopicsCount > 0:
    return false

  if hasEnabledTopics and not enabledTopicsMatch:
    return false

  return normalTopicsMatch

proc getTopicState*(topicName: string): Topic =
  var registry = getTopicsRegistry()
  return registry.topicStatesTable[topicName]

