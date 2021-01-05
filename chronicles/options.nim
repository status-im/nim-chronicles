import
  macros, strutils, strformat, sequtils, os

# The default behavior of Chronicles can be configured through a wide-range
# of compile-time -d: switches (for more information, see the README).
# This module implements the validation of all specified options and reduces
# them to a `Configuration` constant that can be accessed from the rest of
# the modules.

const
  chronicles_enabled {.strdefine.} = "on"
  chronicles_default_output_device* {.strdefine.} = "stdout"

  chronicles_sinks* {.strdefine.} = ""
  chronicles_streams* {.strdefine.} = ""

  chronicles_enabled_topics {.strdefine.} = ""
  chronicles_required_topics {.strdefine.} = ""
  chronicles_disabled_topics {.strdefine.} = ""
  chronicles_runtime_filtering {.strdefine.} = "off"
  chronicles_log_level {.strdefine.} = when defined(debug): "DEBUG"
                                       else: "INFO"
  chronicles_stack_traces {.strdefine.} = when defined(debug): "yes"
                                          else: "no"
  chronicles_timestamps {.strdefine.} = "RfcTime"
  chronicles_colors* {.strdefine.} = "NativeColors"
  chronicles_line_endings {.strdefine.} = "platform"

  chronicles_indent {.intdefine.} = 2
  chronicles_line_numbers {.strdefine.} = "off"

  truthySwitches = ["yes", "1", "on", "true"]
  falsySwitches = ["no", "0", "off", "false", "none"]

when chronicles_streams.len > 0 and chronicles_sinks.len > 0:
  {.error: "Please specify only one of the options 'chronicles_streams' and 'chronicles_sinks'." }
when chronicles_enabled_topics.len > 0 and chronicles_required_topics.len > 0:
  {.error: "Please specify only one of the options 'chronicles_enabled_topics' and 'chronicles_required_topics'." }

type
  LogLevel* = enum
    NONE,
    TRACE,
    DEBUG,
    INFO,
    NOTICE,
    WARN,
    ERROR,
    FATAL

  LogFormatPlugin* = distinct string

  OutputDeviceKind* = enum
    oStdOut,
    oStdErr,
    oFile,
    oSysLog
    oDynamic

  LogFileMode = enum
    Append,
    Truncate

  LogDestination* = object
    case kind*: OutputDeviceKind
    of oFile:
      filename*: string
      truncate*: bool
    else:
      discard

  TimestampScheme* = enum
    NoTimestamps,
    UnixTime,
    RfcTime

  ColorScheme* = enum
    NoColors,
    AnsiColors,
    NativeColors

  LineEndingsScheme* = enum
    windowsLineEndings = "windows"
    posixLineEndings = "posix"
    platformLineEndings = "platform"

  SinkSpec* = object
    format*: LogFormatPlugin
    colorScheme*: ColorScheme
    timestamps*: TimestampScheme
    destinations*: seq[LogDestination]

  StreamSpec* = object
    name*: string
    sinks*: seq[SinkSpec]

  Configuration* = object
    streams*: seq[StreamSpec]

  EnabledTopic* = object
    name*: string
    logLevel*: LogLevel

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

template topicsAsSeq*(topics: string): untyped =
  when topics.len > 0:
    topics.split({','} + Whitespace)
  else:
    newSeq[string](0)

proc topicsWithLogLevelAsSeq(topics: string): seq[EnabledTopic] =
  var sequence = newSeq[EnabledTopic](0)
  if topics.len > 0:
    for topic in split(topics, {','} + Whitespace):
      var values = topic.split(':')
      if values.len > 1:
        if values[1].all(isDigit):
          sequence.add(EnabledTopic(name: values[0],
                                    logLevel: LogLevel(parseInt(values[1]))))
        else:
          sequence.add(EnabledTopic(name: values[0],
                                    logLevel: handleEnumOption(LogLevel,
                                                               values[1])))
      else:
        sequence.add(EnabledTopic(name: values[0], logLevel: NONE))
  return sequence

proc logFormatFromIdent(n: NimNode): LogFormatPlugin =
  let format = $n
  LogFormatPlugin:
    case format.toLowerAscii
    of "json": "chronicles/json_records"
    of "textlines": "chronicles/textlines"
    of "textblocks": "chronicles/textblocks"
    else: format

proc makeSinkSpec(fmt: LogFormatPlugin,
                  colors: ColorScheme,
                  timestamps: TimestampScheme,
                  destinations: varargs[LogDestination]): SinkSpec =
  result.format = fmt
  result.colorScheme = colors
  result.timestamps = timestamps
  result.destinations = @destinations

func logDestinationFromStr(s: string): LogDestination {.compileTime.} =
  case s.toLowerAscii
  of "stdout": result.kind = oStdOut
  of "stderr": result.kind = oStdErr
  of "syslog": result.kind = oSysLog
  of "dynamic": result.kind = oDynamic
  of "file":
    result.kind = oFile
    result.filename = ""
    result.truncate = false
  else:
    error &"'{s}' is not a recognized output device type. " &
           "Allowed values are StdOut, StdErr, SysLog, File and Dynamic."

proc logDestinationFromNode(n: NimNode): LogDestination =
  case n.kind
  of nnkIdent:
    result = logDestinationFromStr($n)
  of nnkCall:
    if n[0].kind != nnkIdent and ($n[0]).toLowerAscii != "file":
      error &"Invalid log destination expression '{n.repr}'. " &
             "Only 'file' destinations accept parameters."
    result.kind = oFile
    result.filename = n[1].repr.replace(" ", "")
    if DirSep != '/': result.filename = result.filename.replace("/", $DirSep)
    if n.len > 2:
      result.truncate = handleEnumOption(LogFileMode, "file mode", $n[2]) == Truncate
  else:
    error &"Invalid log destination expression '{n.repr}'. " &
           "Please refer to the documentation for the supported options."

const
  defaultColorScheme = handleEnumOption(ColorScheme, chronicles_colors)
  defaultTimestamsScheme = handleEnumOption(TimestampScheme, chronicles_timestamps)

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
                              logDestinationFromStr(chronicles_default_output_device))
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
        if dst.kind == oSysLog and not hasExplicitColors:
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
        of oStdOut:
          inc stdoutSinks
          if stdoutSinks > 1: overlappingOutputsError(stream, "stdout")
        of oStdErr:
          inc stderrSinks
          if stderrSinks > 1: overlappingOutputsError(stream, "stderr")
        of oSysLog:
          inc syslogSinks
          if stderrSinks > 1: overlappingOutputsError(stream, "syslog")
          if sink.colorScheme != NoColors:
            error "Using a color scheme is not supported when logging to syslog."
          when not defined(posix):
            warning "Logging to syslog is available only on POSIX systems."
        else: discard

proc parseSinksSpec(spec: string): Configuration {.compileTime.} =
  return parseStreamsSpec(&"{defaultChroniclesStreamName}[{spec}]")

const
  loggingEnabled*    = handleYesNoOption chronicles_enabled
  runtimeFilteringEnabled* = handleYesNoOption chronicles_runtime_filtering

  enabledLogLevel* = handleEnumOption(LogLevel, chronicles_log_level)

  indentStr* = repeat(' ', chronicles_indent)

  newLine* = case handleEnumOption(LineEndingsScheme, chronicles_line_endings)
             of windowsLineEndings: "\r\n"
             of posixLineEndings: "\n"
             of platformLineEndings: "\p"

  stackTracesEnabled* = handleYesNoOption chronicles_stack_traces

  enabledTopics*  = topicsWithLogLevelAsSeq chronicles_enabled_topics
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

