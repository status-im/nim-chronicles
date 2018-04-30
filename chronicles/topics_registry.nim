import macros, tables

type
  TopicState* = enum
    Normal,
    Enabled,
    Required,
    Disabled

  TopicsRegisty* = object
    totalEnabledTopics*: int
    totalRequiredTopics*: int
    topicStatesTable*: Table[string, ptr TopicState]

proc initTopicsRegistry: TopicsRegisty =
  result.topicStatesTable = initTable[string, ptr TopicState]()

var registry* = initTopicsRegistry()

iterator topicStates*: (string, TopicState) =
  for name, state in registry.topicStatesTable:
    yield (name, state[])

proc registerTopic*(name: string, state: ptr TopicState): ptr TopicState =
  registry.topicStatesTable[name] = state
  return state

proc setTopicState*(name: string, newState: TopicState): bool =
  if not registry.topicStatesTable.hasKey(name):
    return false

  var statePtr = registry.topicStatesTable[name]

  case statePtr[]
  of Enabled: dec registry.totalEnabledTopics
  of Required: dec registry.totalRequiredTopics
  else: discard

  case newState
  of Enabled: inc registry.totalEnabledTopics
  of Required: inc registry.totalRequiredTopics
  else: discard

  statePtr[] = newState
  return true

