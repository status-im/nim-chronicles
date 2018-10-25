import os, osproc, streams, macros, queues, threadpool, algorithm, terminal
import json, tables, parseopt, chronicles, chronicles/topics_registry
import strutils, sequtils, unicode, re, parseopt
import compiler / [ast, vmdef, vm, nimeval, options, parser, idents, condsyms,
                   nimconf, extccomp, astalgo, llstream, pathutils]
import prompt

type
  SyntaxError = object of Exception

  Messagekind = enum
    Cmd,
    Log

  Message = object
    content: string
    kind: Messagekind

  Command = enum
    clearFilter,
    clearGrep,
    clearTopics,
    extract,
    filter,
    format,
    grep,
    help,
    quit,
    topics

  RecordPrinter = proc (j: JsonNode)

proc printTextBlock(j: JsonNode)
proc printTextLine(j: JsonNode)
proc printJson(j: JsonNode)

var
  optParser = initOptParser()
  program = ""
  commandLine = ""
  channel: Channel[Message]
  fltr: PNode
  regex = re("")
  recordFormat = ""
  jTest = %*{"msg": "foo", "lvl": "dbg", "ts": 3.14, "topics": "bar", "thread": 0}
  activeRecordPrinter: RecordPrinter = printTextLine
  activeFilter = ""
  activeGrep = ""
  activeTopics = ""

proc createTopicState(name: string): ptr Topic =
  result = getTopicState(name)
  if result == nil:
    return registerTopic(name, create(Topic))

for kind, key, val in optParser.getopt():
  case kind
  of cmdArgument:
    program = key
    commandLine = optParser.cmdLineRest()
    break
  of cmdLongOption, cmdShortOption:
    case key
    of "format":
      case val
        of "json":
          activeRecordPrinter = printJson
        of "textblocks":
          activeRecordPrinter = printTextBlock
        of "textlines":
          activeRecordPrinter = printTextLine
    of "enabled_topics":
      var topics = val.split(Whitespace)
      for t in topics:
        discard createTopicState(t)
        let s = setTopicState(t, Enabled)
        assert s
        activeTopics.add(" +" & t )
    of "disabled_topics":
      var topics = val.split(Whitespace)
      for t in topics:
        discard createTopicState(t)
        let s = setTopicState(t, Disabled)
        assert s
        activeTopics.add(" -" & t )
    of "required_topics":
      var topics = val.split(Whitespace)
      for t in topics:
        discard createTopicState(t)
        let s = setTopicState(t, Required)
        activeTopics.add(" *" & t )
        assert s
  of cmdEnd: discard

proc printUsage() =
  echo """
Usage:
  chronicles-tail [options] program [program-options]

  Topic filtering options:

  --enabled_topics:"topics"
  --disabled_topics:"topics"
  --required_topics:"topics"

  Output formatting options:

  --format:json or textblocks or textlines
"""

if program.len == 0:
  echo "Please specify a program to run\n"
  printUsage()
  quit 1

proc parse*(s: string): PNode =
  var conf = newConfigRef()
  conf.verbosity = 0
  var cache = newIdentCache()
  condsyms.initDefines(conf.symbols)
  conf.projectName = "stdinfile"
  conf.projectFull = AbsoluteFile("stdinfile")
  let cwd = AbsoluteFile(getCurrentDir())
  conf.projectPath = AbsoluteDir(canonicalizePath(conf, cwd))
  conf.projectIsStdin = true
  loadConfigs(DefaultConfig, cache, conf)
  extccomp.initVars(conf)
  result = parseString(s, cache, conf)

# Handling keyboard inputs with the edited mofunoise library

const commands = [
  ("!filter", "clears the active filter"),
  ("!grep", "clears the active grep"),
  ("!topics", "clears active topics"),
  ("extract", "shows only certain properties of the log statement"),
  ("filter",
      """shows only statements with the specified property. E.g.: lvl == "DEBUG" """),
  ("format",
      "sets the format of the log outputs - textblocks, textlines or json"),
  ("grep", "uses regular expressions to filter the log"),
  ("help", "shows this help"),
  ("quit", "quits the program"),
  ("topics", """filters by topic using the operators +, - and *. Ex.: topics +enabled_topic -disabled_topic *required_topic +another_enabled_topic """)
]

static: assert commands.len == int(high(Command)) + 1

proc provideCompletions*(pline: seq[Rune], cursorPos: int): seq[string] =
  result = @[]
  var line = ""
  for i in 0 ..< pline.len:
    add(line, $pline[i])
  var firstWord = line[0..(cursorPos-1)]
  var index = lowerBound(commands, (firstWord, ""))
  if commands.len < index + 1:
    return
  if not startsWith(commands[index][0], firstWord):
    return
  var i = 0
  while index + i < commands.len and
        startsWith(commands[index+i][0], firstWord):
    result.add commands[index + i][0]
    i += 1

var p = Prompt.init("chronicles > ", provideCompletions)
p.useHistoryFile()

proc pSaveHistory(){.noconv.} =
  try:
    p.saveHistory()
  except IOError:
    p.writeLine("Error saving history to " & p.historyPath)

addQuitProc pSaveHistory

open(channel)

var pAddr = addr(p)
proc print(s: string) = pAddr[].writeline s

proc ctrlCHandler() {.noconv.} = quit 0
setControlCHook ctrlCHandler

proc printHelp() =
  for el in commands:
    var spaces = repeat(" ", 18-el[0].len)
    if el[1].len > 50:
      var line1 = el[1][0 .. 50]
      var line2 = el[1][51 .. ^1]
      var empty = repeat(" ", 18)
      print el[0] & spaces & line1 & "\n\r" & empty & line2
    else:
      print el[0] & spaces & el[1]

proc printRecord(Record: type, j: JsonNode) =
  var record: Record
  let severity = parseEnum[LogLevel](j["lvl"].str)
  let msg = j["msg"].str
  let topic = j["topics"].str

  pAddr[].withOutput do ():
    initLogRecord(record, severity, topic, msg)
    delete(j, "msg")
    delete(j, "lvl")
    delete(j, "ts")
    delete(j, "topics")
    var b = true
    for field, value in j:
      if b:
        record.setFirstProperty($field, value)
        b = false
      else:
        case value.kind
        of JString:
          record.setProperty($field, value.str)
        of JInt:
          record.setProperty($field, value.num)
        of JFloat:
          record.setProperty($field, value.fnum)
        of JBool:
          record.setProperty($field, value.bval)
        of JNull:
          assert false
        of JObject:
          record.setProperty($field, $value)
        of JArray:
          record.setProperty($field, value.elems)
    flushRecord(record)

proc printTextBlock(j: JsonNode) =
  printRecord(TextBlockRecord[StdOutOutput, RfcTime, NativeColors], j)

proc printTextLine(j: JsonNode) =
  printRecord(TextLineRecord[StdOutOutput, RfcTime, NativeColors], j)

proc printJson(j: JsonNode) =
  printRecord(JsonRecord[StdOutOutput, RfcTime], j)

proc compare(r: JsonNode, n: PNode): int =
  case r.kind
  of JString:
    if n.kind == nkStrLit:
      return cmpIgnoreCase(r.str, n.strVal)
  of JInt:
    if n.kind == nkIntLit:
      return cmp(r.num, n.intVal)
  of JFloat:
    if n.kind == nkFloatLit:
      return cmp(r.fnum, n.floatVal)
  of JBool:
    if n.intVal == 0 or n.intVal == 1:
      return cmp(BiggestInt(r.bval), n.intVal)
  of JNull:
    if n.kind == nkNilLit:
      return 0
  of JObject:
    raise newException(ValueError, "Type object is not supported")
  of JArray:
    if n.kind == nkBracket:
      let minlen = min(n.sons.len, r.elems.len)
      for i in 0 ..< minlen:
        var res = compare(r.elems[i], n.sons[i])
        if res == 0:
          return n.sons.len - r.elems.len
        else:
          return res
  raise newException(ValueError,
    "The value in your filter is of a different type than the json value")

#Proc 'matches' returns true if a record 'r' matches a filtering condition 'n'.
proc matches(n: PNode, r: JsonNode, allowMissingFields: bool): bool =
  if n == nil:
    return true
  else:
    case n.kind
    of nkStmtList:
      return matches(n[0], r, allowMissingFields)
    of nkInfix:
      assert n[0].kind == nkIdent
      case n[0].ident.s
      of "or":
        return matches(n[1], r, allowMissingFields) or
               matches(n[2], r, allowMissingFields)
      of "and":
        return matches(n[1], r, allowMissingFields) and
               matches(n[2], r, allowMissingFields)
      of "==":
        if n[1].kind != nkIdent:
          raise newException(SyntaxError, "Syntax error")
        let jsonPropertyName = n[1].ident.s
        if r.hasKey(jsonPropertyName):
          if compare(r[jsonPropertyName], n[2]) == 0:
            return true
          return false
        return allowMissingFields
      of ">":
        if n[1].kind != nkIdent:
          raise newException(SyntaxError, "Syntax error")
        let jsonPropertyName = n[1].ident.s
        if r.hasKey(jsonPropertyName):
          if compare(r[jsonPropertyName], n[2]) > 0:
            return true
          return false
        return allowMissingFields
      of "<":
        if n[1].kind != nkIdent:
          raise newException(SyntaxError, "Syntax error")
        let jsonPropertyName = n[1].ident.s
        if r.hasKey(jsonPropertyName):
          if compare(r[jsonPropertyName], n[2]) < 0:
            return true
          return false
        return allowMissingFields
      of "in":
        if n[2].kind != nkBracket:
          raise newException(SyntaxError,
            "Please, enter a valid nim expression")
        let jsonPropertyName = n[1].ident.s
        if r.hasKey(jsonPropertyName):
          for i in n[2].sons:
            if compare(r[jsonPropertyName], i) == 0:
              return true
            return false
        return allowMissingFields
      else:
        raise newException(SyntaxError, "Unsupported operator")
    else:
      raise newException(SyntaxError, "Syntax Error")

proc matchRE(s: string, re: Regex): bool =
  if find(s, re) > -1:
    return true
  return false

proc handleCommand(line: string) =
  var pos = find(line, " ")
  var cmdParam = ""
  var firstWord: string #'firstWord' is expected to be a command or command shortcut
  if pos > 0:
    firstWord = line[0..(pos-1)]
    cmdParam = line[(pos+1)..line.high] #command parameters
  else:
    firstWord = line
  var index = lowerBound(commands, (firstWord, ""))
  var currentCmd: string
  var nextCmd: string
  if commands.len < index + 1:
    print "Wrong command"
    return
  elif commands.len == index + 1:
    currentCmd = commands[index][0]
    nextCmd = ""
  else:
    currentCmd = commands[index][0]
    nextCmd = commands[index + 1][0]

  if not startsWith(currentCmd, firstWord):
    print "Wrong command"
    return
  if startsWith(nextCmd, firstWord):
    print "Did you mean " & currentCmd & " or " & nextCmd & "?"
    return
  var command = Command(index)

  case command
  of clearFilter:
    fltr = nil
    activeFilter = ""
    print "clearing filter"
  of clearGrep:
    print "clearing grep"
    regex = re("")
    activeGrep = ""
  of clearTopics:
    clearTopicsRegistry()
    activeTopics = ""
  of extract:
    print "extracting"
  of filter:
    if pos < 0:
      print "Please, enter a parameter for filter"
      return
    try:
      let parsed = parse(cmdParam)
      discard matches(parsed, jTest, false)
      fltr = parsed
      activeFilter = cmdParam
    except:
      print "Error: " & getCurrentExceptionMsg()
  of format:
    print "formatting"
    if cmdParam == "textblocks":
      activeRecordPrinter = printTextBlock
    elif cmdParam == "textlines":
      activeRecordPrinter = printTextLine
    elif cmdParam == "json":
      activeRecordPrinter = printJson
    else:
      print "Please, enter a valid format: TextBlockRecord, TextLineRecord or JsonRecord"
  of grep:
    if pos < 0:
      print "Please, enter a parameter for grep"
      return
    try:
      regex = re(cmdParam, {reIgnoreCase, reStudy})
      activeGrep = cmdParam
    except:
      print "Error: " & getCurrentExceptionMsg()
  of help:
    printHelp()
  of quit:
    quit(0)
  of topics:
    clearTopicsRegistry()
    #echo repr(registry.topicStatesTable)
    var params = cmdParam.split(Whitespace)
    if cmdParam == "":
      print "Please, enter a parameter for grep"
    for p in params:
      if p.len == 0:
        continue
      var operator = p[0]
      var topic = p[1 .. ^1]
      if operator notin ['+', '-', '*']:
        print "Syntax Error"
        return
      activeTopics = cmdParam
      if operator == '+':
        discard createTopicState(topic)
        let s = setTopicState(topic, Enabled)
        assert s
      elif operator == '-':
        discard createTopicState(topic)
        let s = setTopicState(topic, Disabled)
        assert s
      elif operator == '*':
        discard createTopicState(topic)
        let s = setTopicState(topic, Required)
        assert s

proc inputThread {.thread.} =
  try:
    while true:
      var msg: Message
      msg.kind = Cmd
      msg.content = pAddr[].readLine()
      send(channel, msg)
  except:
    let ex = getCurrentException()
    # print ex.getStackTrace
    # print ex.msg
    quit 1

spawn inputThread()

var process = startProcess(command = program, args = [commandLine], workingDir = getCurrentDir())

proc quitProc(){.noconv.} = terminate(process)
system.addQuitProc(quitProc)

# Transform json input into TextBlockRecord/TextLineRecord or JsonRecord
proc processTailingThread(process: Process) =
  var msg: Message
  msg.kind = Log
  for line in outputStream(process).lines:
    msg.content = line
    send(channel, msg)

spawn processTailingThread(process)

proc checkType(j: JsonNode, key: string, kind: JsonNodeKind): bool =
  j.hasKey(key) and j[key].kind == kind

proc setStatus() =
  var statusBar: seq[StatusBarItem] = @[]
  if activeTopics != "" :
    statusBar.add(("topics", activeTopics))
  if activeFilter != "" :
    statusBar.add(("filter", activeFilter))
  if activeGrep != "" :
    statusBar.add(("grep", activeGrep))
  p.setStatusBar(statusBar)

setStatus()

proc mainLoop() =
  var msg: Message
  while true:
    msg = recv(channel)
    if msg.kind == Cmd:
      handleCommand(msg.content)
      setStatus()
    if msg.kind == Log:
      if matchRE(msg.content, regex):
        var j = parseJson(msg.content)
        var t = j["topics"].str
        var topics = t.split(Whitespace + {',', ';'})
        var topicStates: seq[ptr Topic] = @[]
        for t in topics:
          topicStates.add(createTopicState(t))
          #print (t & $(createTopicState(t)[]))
        if j.kind == JObject and
           j.checkType("ts", JString) and
           j.checkType("lvl", JString) and
           j.checkType("msg", JString) and
           j.checkType("topics", JString) and
           topicsMatch(topicStates) and
           matches(fltr, j, false):
          activeRecordPrinter(j)
        else:
          discard
      else:
        discard

mainLoop()
