import
  macros, strutils, strformat, sequtils, ospaths

const
  chronicles_enabled {.strdefine.} = "on"
  chronicles_enabled_topics {.strdefine.} = ""
  chronicles_required_topics {.strdefine.} = ""
  chronicles_disabled_topics {.strdefine.} = ""
  chronicles_log_level {.strdefine.} = when defined(debug): "ALL"
                                       else: "NOTICE"

  chronicles_runtime_filtering {.strdefine.} = "off"
  chronicles_timestamps {.strdefine.} = "on"
  chronicles_sinks* {.strdefine.} = ""
  chronicles_streams* {.strdefine.} = ""
  chronicles_indent {.intdefine.} = 2
  chronicles_colors* {.strdefine.} = "on"

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

  LogFormat* = enum
    json,
    textLines,
    textBlocks

  LogDestinationKind* = enum
    toStdOut,
    toStdErr,
    toFile,
    toSysLog

  LogDestination* = object
    case kind*: LogDestinationKind
    of toFile:
      outputId*: int
      filename*: string
    else:
      discard

  ColorScheme* = enum
    NoColors,
    AnsiColors,
    PlatformSpecificColors

  SinkSpec* = object
    format*: LogFormat
    colorScheme*: ColorScheme
    destinations*: seq[LogDestination]

  StreamSpec* = object
    name*: string
    sinks*: seq[SinkSpec]

  Configuration* = object
    totalFileOutputs*: int
    streams*: seq[StreamSpec]

proc handleYesNoOption(optName: string,
                       optValue: string): bool {.compileTime.} =
  let canonicalValue = optValue.toLowerAscii
  if canonicalValue in ["yes", "1", "on", "true"]:
    return true
  elif canonicalValue in ["no", "0", "off", "false"]:
    return false
  else:
    error &"A non-recognized value '{optValue}' for option '{optName}'. " &
           "Please specify either 'on' or 'off'."

template handleYesNoOption(opt: untyped): bool =
  handleYesNoOption(astToStr(opt), opt)

proc handleEnumOption(T: typedesc[enum],
                      optName: string,
                      optValue: string): T {.compileTime.} =
  try: return parseEnum[T](optValue)
  except: error &"'{optValue}' is not a recognized value for '{optName}'. " &
                &"Allowed values are {enumValues(T)}"

proc enumValues(E: typedesc[enum]): string =
  result = mapIt(E, $it).join(", ")

template topicsAsSeq(topics: string): untyped =
  when topics.len > 0:
    topics.split(Whitespace)
  else:
    newSeq[string](0)

proc logFormatFromIdent(n: NimNode): LogFormat =
  let format = $n
  case format.toLowerAscii
  of "json":
    return json
  of "textlines":
    return textLines
  of "textblocks":
    return textBlocks
  else:
    error &"'{format}' is not a recognized output format. " &
           "Allowed values are {enumValues LogFormat}."

proc makeSinkSpec(fmt: LogFormat, colors: ColorScheme,
                  destinations: varargs[LogDestination]): SinkSpec =
  result.format = fmt
  result.colorScheme = colors
  result.destinations = @destinations

proc logDestinationFromNode(n: NimNode): LogDestination =
  case n.kind
  of nnkIdent:
    let destination = $n
    case destination.toLowerAscii
    of "stdout": result.kind = toStdOut
    of "stderr": result.kind = toStdErr
    of "syslog": result.kind = toSysLog
    of "file":
      result.kind = toFile
      result.filename = ""
    else:
      error &"'{destination}' is not a recognized log destination. " &
             "Allowed values are StdOut, StdErr, SysLog and File."
  of nnkCall:
    if n[0].kind != nnkIdent and ($n[0]).toLowerAscii != "file":
      error &"Invalid log destination expression '{n.repr}'. " &
             "Only 'file' destinations accept parameters."
    result.kind = toFile
    result.filename = n[1].repr.replace(" ", "")
    if DirSep != '/': result.filename = replace("/", $DirSep)
  else:
    error &"Invalid log destination expression '{n.repr}'. " &
           "Please refer to the documentation for the supported options."

const
  defaultColorScheme = when handleYesNoOption(chronicles_colors): AnsiColors
                       else: NoColors

proc syntaxCheckStreamExpr*(n: NimNode) =
  if n.kind != nnkBracketExpr or n[0].kind != nnkIdent:
      error &"Invalid stream definition. " &
             "Please use a bracket expressions such as 'stream_name[sinks_list]'."

proc sinkSpecsFromNode*(streamNode: NimNode): seq[SinkSpec] =
  newSeq(result, 0)
  for i in 1 ..< streamNode.len:
    let n = streamNode[i]
    case n.kind
    of nnkIdent:
      result.add makeSinkSpec(logFormatFromIdent(n), defaultColorScheme,
                              LogDestination(kind: toStdOut))
    of nnkBracketExpr:
      var spec = makeSinkSpec(logFormatFromIdent(n[0]), NoColors)
      for i in 1 ..< n.len:
        spec.destinations.add logDestinationFromNode(n[i])
      result.add spec
    else:
      error &"Invalid log sink expression '{n.repr}'. " &
             "Please refer to the documentation for the supported options."

proc parseStreamsSpec(spec: string): Configuration {.compileTime.} =
  newSeq(result.streams, 0)
  var specNodes = parseExpr "(" & spec.replace("\\", "/") & ")"
  for n in specNodes:
    syntaxCheckStreamExpr(n)
    let streamName = $n[0]
    for prev in result.streams:
      if prev.name == streamName:
        error &"The stream name '{streamName}' appears twice in the 'chronicles_streams' definition."

    result.streams.add StreamSpec(name: streamName,
                                  sinks: sinkSpecsFromNode(n))

  proc overlappingOutputsError(stream: StreamSpec, outputName: string) =
    # XXX: This must be a proc until https://github.com/nim-lang/Nim/issues/7632 is fixed
    error &"In the {stream.name} stream, there are multiple output formats pointed " &
          &"to {outputName}. This is not a supported configuration."

  for stream in mitems(result.streams):
    var stdoutSinks = 0
    var stderrSinks = 0
    for sink in mitems(stream.sinks):
      for dst in mitems(sink.destinations):
        case dst.kind
        of toFile:
          dst.outputId = result.totalFileOutputs
          inc result.totalFileOutputs
        of toStdOut:
          inc stdoutSinks
          if stdoutSinks > 1: overlappingOutputsError(stream, "stdout")
        of toStdErr:
          inc stderrSinks
          if stderrSinks > 1: overlappingOutputsError(stream, "stderr")
        else: discard

proc parseSinksSpec(spec: string): Configuration {.compileTime.} =
  return parseStreamsSpec(&"defaultStream[{spec}]")

when chronicles_streams.len > 0 and chronicles_sinks.len > 0:
  {.error: "Please specify only one of the options 'chronicles_streams' and 'chronicles_sinks'." }

const
  timestampsEnabled* = handleYesNoOption chronicles_timestamps
  loggingEnabled*    = handleYesNoOption chronicles_enabled
  runtimeFilteringEnabled* = handleYesNoOption chronicles_runtime_filtering

  enabledLogLevel* = handleEnumOption(LogLevel,
                                      "chronicles_log_level",
                                      chronicles_log_level.toUpperAscii)

  textBlockIndent* = repeat(' ', chronicles_indent)

  enabledTopics*  = topicsAsSeq chronicles_enabled_topics
  disabledTopics* = topicsAsSeq chronicles_disabled_topics
  requiredTopics* = topicsAsSeq chronicles_required_topics

  config* = when chronicles_streams.len > 0: parseStreamsSpec(chronicles_streams)
            elif chronicles_sinks.len > 0:   parseSinksSpec(chronicles_sinks)
            else: parseSinksSpec "textblocks"

