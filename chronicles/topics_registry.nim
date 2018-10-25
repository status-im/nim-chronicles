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

  TopicsRegisty* = object
    totalEnabledTopics*: int
    totalRequiredTopics*: int
    topicStatesTable*: Table[string, ptr Topic]

proc initTopicsRegistry: TopicsRegisty =
  result.topicStatesTable = initTable[string, ptr Topic]()

var registry* = initTopicsRegistry()

proc clearTopicsRegistry* =
  registry.totalEnabledTopics = 0
  registry.totalRequiredTopics = 0
  for val in registry.topicStatesTable.values:
    val.state = Normal

iterator topicStates*: (string, TopicState) =
  for name, topic in registry.topicStatesTable:
    yield (name, topic.state)

proc registerTopic*(name: string, topic: ptr Topic): ptr Topic =
  registry.topicStatesTable[name] = topic
  return topic

proc setTopicState*(name: string,
                    newState: TopicState,
                    logLevel = LogLevel.NONE): bool =
  if not registry.topicStatesTable.hasKey(name):
    return false

  var topicPtr = registry.topicStatesTable[name]

  case topicPtr.state
  of Enabled: dec registry.totalEnabledTopics
  of Required: dec registry.totalRequiredTopics
  else: discard

  case newState
  of Enabled: inc registry.totalEnabledTopics
  of Required: inc registry.totalRequiredTopics
  else: discard

  topicPtr.state = newState
  topicPtr.logLevel = logLevel

  return true

proc topicsMatch*(topics: openarray[ptr Topic]): bool =
  if topics.len == 0:
    return true
  var matchEnabledTopics = registry.totalEnabledTopics == 0
  var requiredTopicsCount = registry.totalRequiredTopics
  for topic in topics:
    case topic.state
    of Normal: discard
    of Enabled: matchEnabledTopics = true
    of Disabled: return false
    of Required: dec requiredTopicsCount
  return matchEnabledTopics and requiredTopicsCount == 0

proc getTopicState*(topic: string): ptr Topic =
  return registry.topicStatesTable.getOrDefault(topic)

