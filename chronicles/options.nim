import
  macros, strutils, strformat, sequtils, ospaths

# The default behavior of Chronicles can be configured through a wide-range
# of compile-time -d: switches. This module implements the validation of all
# specified options and reducing them to a `Configuration` constant that can
# be accessed from the rest of the modules.

const
  chronicles_enabled {.strdefine.} = "on"
    ## Disabling this option will competely remove all chronicles-related code
    ## from the target binary.

  chronicles_enabled_topics {.strdefine.} = ""
    ## You can use this option to specify a comma-separated list of topics for
    ## which the logging statements should produce output. All other logging
    ## statements will be erased from the final code at compile time.
    ## When the list includes multiple topics, any of them is considered a match.

  chronicles_required_topics {.strdefine.} = ""
    ## Similar to `chronicles_enabled_topics`, but requires the logging statements
    ## to have all topics specified in the list.

  chronicles_disabled_topics {.strdefine.} = ""
    ## The dual of `chronicles_enabled_topics`. The option specifies a black-list
    ## of topics for which the associated logging statements should be erased from
    ## the program.

  chronicles_log_level {.strdefine.} = when defined(debug): "ALL"
                                       else: "INFO"
    ## This option can be used to erase all log statements, not matching the
    ## specified minimum log level at compile-time.

  chronicles_runtime_filtering {.strdefine.} = "off"
    ## This option enables the run-filtering capabilities of chronicles.
    ## The run-time filtering is controlled through the procs `setLogLevel`
    ## and `setTopicState`.

  chronicles_timestamps {.strdefine.} = "RfcTime"
    ## This option controls the use of timestamps in the log output.
    ## Possible values are:
    ##
    ## - RfcTime (used by default)
    ##
    ##   Chronicles will use the human-readable format specified in
    ##   RFC 3339: Date and Time on the Internet: Timestamps
    ##
    ##   https://tools.ietf.org/html/rfc3339
    ##
    ## - UnixTime
    ##
    ##   Chronicles will write a single float value for the number
    ##   of seconds since the "Unix epoch"
    ##
    ##   https://en.wikipedia.org/wiki/Unix_time
    ##
    ## - NoTimestamps
    ##
    ##   Chronicles will not include timestamps in the log output.
    ##
    ## Please note that the timestamp format can also be specified
    ## for individual sinks (see `chronicles_sinks`).

  chronicles_sinks* {.strdefine.} = ""
  chronicles_streams* {.strdefine.} = ""
  chronicles_indent {.intdefine.} = 2
  chronicles_colors* {.strdefine.} = "on"

when chronicles_streams.len > 0 and chronicles_sinks.len > 0:
  {.error: "Please specify only one of the options 'chronicles_streams' and 'chronicles_sinks'." }

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

  TimestampsScheme* = enum
    NoTimestamps,
    UnixTime,
    RfcTime

  ColorScheme* = enum
    NoColors,
    AnsiColors,
    NativeColors

  SinkSpec* = object
    format*: LogFormat
    colorScheme*: ColorScheme
    timestamps*: TimestampsScheme
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

proc enumValues(E: typedesc[enum]): string =
  result = mapIt(E, $it).join(", ")

proc handleEnumOption(E: typedesc[enum],
                      optName: string,
                      optValue: string): E {.compileTime.} =
  try: return parseEnum[E](optValue)
  except: error &"'{optValue}' is not a recognized value for '{optName}'. " &
                &"Allowed values are {enumValues E}"

template handleEnumOption(E, varName: untyped): auto =
  handleEnumOption(E, astToStr(varName), varName)

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

proc makeSinkSpec(fmt: LogFormat,
                  colors: ColorScheme,
                  timestamps: TimestampsScheme,
                  destinations: varargs[LogDestination]): SinkSpec =
  result.format = fmt
  result.colorScheme = colors
  result.timestamps = timestamps
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

  defaultTimestamsScheme = handleEnumOption(TimestampsScheme, chronicles_timestamps)

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
      result.add makeSinkSpec(logFormatFromIdent(n),
                              defaultColorScheme,
                              defaultTimestamsScheme,
                              LogDestination(kind: toStdOut))
    of nnkBracketExpr:
      var spec = makeSinkSpec(logFormatFromIdent(n[0]),
                              defaultColorScheme,
                              defaultTimestamsScheme)
      for i in 1 ..< n.len:
        var hasExplicitColors = false

        template setColors(c) =
          spec.colorScheme = c
          hasExplicitColors = true
          continue

        template setTimestamps(t) =
          spec.timestamps = t
          continue

        let dstSpec = n[i]
        if dstSpec.kind == nnkIdent:
          case ($dstSpec).toLowerAscii:
          of "nocolors": setColors(NoColors)
          of "ansicolors": setColors(AnsiColors)
          of "nativecolors": setColors(NativeColors)
          of "notimestamps": setTimestamps(NoTimestamps)
          of "unixtime": setTimestamps(UnixTime)
          of "rfctime": setTimestamps(RfcTime)
          else: discard

        let dst = logDestinationFromNode(dstSpec)
        if dst.kind == toSysLog and not hasExplicitColors:
          spec.colorScheme = NoColors

        spec.destinations.add dst
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
    var syslogSinks = 0
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
        of toSysLog:
          inc syslogSinks
          if stderrSinks > 1: overlappingOutputsError(stream, "syslog")
          if sink.colorScheme != NoColors:
            error "Using a color scheme is not supported when logging to syslog."
          when not defined(posix):
            warn "Logging to syslog is available only on POSIX systems."
        else: discard

proc parseSinksSpec(spec: string): Configuration {.compileTime.} =
  return parseStreamsSpec(&"defaultStream[{spec}]")

const
  loggingEnabled*    = handleYesNoOption chronicles_enabled
  runtimeFilteringEnabled* = handleYesNoOption chronicles_runtime_filtering

  enabledLogLevel* = handleEnumOption(LogLevel, chronicles_log_level)

  textBlockIndent* = repeat(' ', chronicles_indent)

  enabledTopics*  = topicsAsSeq chronicles_enabled_topics
  disabledTopics* = topicsAsSeq chronicles_disabled_topics
  requiredTopics* = topicsAsSeq chronicles_required_topics

  config* = when chronicles_streams.len > 0: parseStreamsSpec(chronicles_streams)
            elif chronicles_sinks.len > 0:   parseSinksSpec(chronicles_sinks)
            else: parseSinksSpec "textblocks"

