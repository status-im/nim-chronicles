import
  macros, strutils, strformat, sequtils

type
  LogLevel* = enum
    ALL,
    DEBUG,
    INFO,
    NOTICE,
    WARN,
    ERROR,
    FATAL,
    NONE

proc handleYesNoOption(optName: string,
                       optValue: string): bool {.compileTime.} =
  let canonicalValue = optValue.toLowerAscii
  if canonicalValue in ["yes", "1", "on", "true"]:
    return true
  elif canonicalValue in ["no", "0", "off", "false"]:
    return false
  else:
    error &"A non-recognized value '{optValue}' for option '{optName}'. Please specify either 'on' or 'off'."

template handleYesNoOption(opt: untyped): bool =
  handleYesNoOption(astToStr(opt), opt)

proc handleEnumOption(T: typedesc[enum],
                      optName: string,
                      optValue: string): T {.compileTime.} =
  try: return parseEnum[T](optValue)
  except: error &"'{optValue}' is not a recognized value for '{optName}'. Allowed values are {enumValues(T)}"

proc enumValues(E: typedesc[enum]): string =
  result = mapIt(E, $it).join(", ")

template topicsAsSeq(topics: string): untyped =
  when topics.len > 0:
    topics.split(Whitespace)
  else:
    newSeq[string](0)

const
  chronicles_enabled {.strdefine.} = "on"
  chronicles_enabled_topics {.strdefine.} = ""
  chronicles_disabled_topics {.strdefine.} = ""
  chronicles_log_level {.strdefine.} = when defined(debug): "ALL"
                                       else: "NOTICE"

  chronicles_timestamps {.strdefine.} = "on"
  chronicles_sinks* {.strdefine.} = ""
  chronicles_indent {.intdefine.} = 2

  timestampsEnabled* = handleYesNoOption chronicles_timestamps
  loggingEnabled*    = handleYesNoOption chronicles_enabled

  enabledLogLevel* = handleEnumOption(LogLevel,
                                      "chronicles_log_level",
                                      chronicles_log_level.toUpperAscii)

  textBlockIndent* = repeat(' ', chronicles_indent)

  enabledTopics*  = topicsAsSeq chronicles_enabled_topics
  disabledTopics* = topicsAsSeq chronicles_disabled_topics

