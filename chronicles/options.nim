import
  macros, strutils, strformat, sequtils, ospaths

# The default behavior of Chronicles can be configured through a wide-range
# of compile-time -d: switches (for more information, see the README).
# This module implements the validation of all specified options and reduces
# them to a `Configuration` constant that can be accessed from the rest of
# the modules.

const
  chronicles_enabled {.strdefine.} = "on"
  chronicles_sinks* {.strdefine.} = ""
  chronicles_streams* {.strdefine.} = ""

  chronicles_enabled_topics {.strdefine.} = ""
  chronicles_required_topics {.strdefine.} = ""
  chronicles_disabled_topics {.strdefine.} = ""
  chronicles_runtime_filtering {.strdefine.} = "off"
  chronicles_log_level {.strdefine.} = when defined(release): "INFO"
                                       else: "DEBUG"

  chronicles_timestamps {.strdefine.} = "RfcTime"
  chronicles_colors* {.strdefine.} = "NativeColors"

  chronicles_indent {.intdefine.} = 2
  chronicles_line_numbers {.strdefine.} = "off"

  truthySwitches = ["yes", "1", "on", "true"]
  falsySwitches = ["no", "0", "off", "false", "none"]

when chronicles_streams.len > 0 and chronicles_sinks.len > 0:
  {.error: "Please specify only one of the options 'chronicles_streams' and 'chronicles_sinks'." }

type
  LogLevel* = enum
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

  LogFileMode = enum
    Append,
    Truncate

  LogDestination* = object
    case kind*: LogDestinationKind
    of toFile:
      filename*: string
      truncate*: bool
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
    streams*: seq[StreamSpec]

const defaultChroniclesStreamName* = "defaultChroniclesStream"

proc handleYesNoOption(optName: string,
                       optValue: string): bool {.compileTime.} =
  let canonicalValue = optValue.toLowerAscii
  if canonicalValue in truthySwitches:
    return true
  elif canonicalValue in falsySwitches:
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
  try:
    if optValue.toLowerAscii in falsySwitches:
      type R = type(result)
      return R(0)
    else:
      return parseEnum[E](optValue)
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
          &"Allowed values are {enumValues LogFormat}."

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
      result.truncate = false
    else:
      error &"'{destination}' is not a recognized log destination. " &
             "Allowed values are StdOut, StdErr, SysLog and File."
  of nnkCall:
    if n[0].kind != nnkIdent and ($n[0]).toLowerAscii != "file":
      error &"Invalid log destination expression '{n.repr}'. " &
             "Only 'file' destinations accept parameters."
    result.kind = toFile
    result.filename = n[1].repr.replace(" ", "")
    if DirSep != '/': result.filename = result.filename.replace("/", $DirSep)
    if n.len > 2:
      result.truncate = handleEnumOption(LogFileMode, "file mode", $n[2]) == Truncate
  else:
    error &"Invalid log destination expression '{n.repr}'. " &
           "Please refer to the documentation for the supported options."

const
  defaultColorScheme = handleEnumOption(ColorScheme, chronicles_colors)
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
            warning "Logging to syslog is available only on POSIX systems."
        else: discard

proc parseSinksSpec(spec: string): Configuration {.compileTime.} =
  return parseStreamsSpec(&"defaultChroniclesStream[{spec}]")

const
  loggingEnabled*    = handleYesNoOption chronicles_enabled
  runtimeFilteringEnabled* = handleYesNoOption chronicles_runtime_filtering

  enabledLogLevel* = handleEnumOption(LogLevel, chronicles_log_level)

  textBlockIndent* = repeat(' ', chronicles_indent)

  enabledTopics*  = topicsAsSeq chronicles_enabled_topics
  disabledTopics* = topicsAsSeq chronicles_disabled_topics
  requiredTopics* = topicsAsSeq chronicles_required_topics
  lineNumbersEnabled* = handleYesNoOption chronicles_line_numbers

  config* = when chronicles_streams.len > 0: parseStreamsSpec(chronicles_streams)
            elif chronicles_sinks.len > 0:   parseSinksSpec(chronicles_sinks)
            # default is textlines because:
            # * better compatibility with typical log processing tools
            #   like grep, logstash etc where newline delieates events or units
            # * easier to match with a regex
            # * good use of screen real estate
            # * wins nimbus developer straw poll
            # alternatively, one could prefer to use "textblocks" - it can be
            # enabled by passing -d:chronicles_sinks=textblocks
            # * some tools understand that indented lines following newline
            #   "belong" to the same logging eevent
            # * wrapping more likely to happen making line hard to read on
            #   narrow terminals
            # * properies may be easier to find
            else: parseSinksSpec "textlines"
