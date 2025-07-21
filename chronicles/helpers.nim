import
  std/[tables, strutils, strformat],
  ./topics_registry

export tables

func parseTopicDirectives*(directives: openArray[string]): Table[string, SinkTopicSettings] =
  result = initTable[string, SinkTopicSettings]()

  for directive in directives:
    let subDirectives = directive.split(";")
    for directive in subDirectives:
      let parts = directive.split(":")
      if parts.len != 2:
        raise newException(ValueError, "Please use the following syntax 'DEBUG: topic1,topic2; INFO: topic3'.")

      let topicsNames = parts[1].split(",")

      template forEachTopic(body) =
        for name2 in topicsNames:
          let name = name2.strip
          if not result.hasKey(name):
            result.add(name, default(SinkTopicSettings))
          template topic: auto = result[name]
          body

      case toLowerAscii(parts[0].strip)
      of "required":
        forEachTopic: topic.state = Required
      of "disabled":
        forEachTopic: topic.state = Disabled
      of "trc", "trace":
        forEachTopic: topic.logLevel = TRACE
      of "dbg", "debug":
        forEachTopic: topic.logLevel = DEBUG
      of "inf", "info":
        forEachTopic: topic.logLevel = INFO
      of "ntc", "notice", #[legacy compatibility:]# "not":
        forEachTopic: topic.logLevel = NOTICE
      of "wrn", "warn":
        forEachTopic: topic.logLevel = WARN
      of "err", "error":
        forEachTopic: topic.logLevel = ERROR
      of "fat", "fatal":
        forEachTopic: topic.logLevel = FATAL
      else:
        raise newException(ValueError, &"'{parts[0]}' is not a recognized log level.")
