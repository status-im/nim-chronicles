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
    topicStatesTable*: Table[string, ptr Topic]

var
  gActiveLogLevel: LogLevel
  gTotalEnabledTopics: int
  gTotalRequiredTopics: int
  gTopicStates = initTable[string, ptr Topic]()

proc setLogLevel*(lvl: LogLevel) =
  gActiveLogLevel = lvl

proc clearTopicsRegistry* =
  gTotalEnabledTopics = 0
  gTotalRequiredTopics = 0
  for val in gTopicStates.values:
    val.state = Normal

iterator topicStates*: (string, TopicState) =
  for name, topic in gTopicStates:
    yield (name, topic.state)

proc registerTopic*(name: string, topic: ptr Topic): ptr Topic =
  gTopicStates[name] = topic
  return topic

proc setTopicState*(name: string,
                    newState: TopicState,
                    logLevel = LogLevel.NONE): bool =
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
                  logStmtTopics: openarray[ptr Topic]): bool =
  var
    hasEnabledTopics = gTotalEnabledTopics > 0
    enabledTopicsMatch = false
    normalTopicsMatch = logStmtTopics.len == 0
    requiredTopicsCount = gTotalRequiredTopics

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

proc getTopicState*(topic: string): ptr Topic =
  return gTopicStates.getOrDefault(topic)

