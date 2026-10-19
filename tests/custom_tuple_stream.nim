import
  chronicles

type
  MyRecord[Output] = object
    output*: Output
    line*: string

  Records = (MyRecord[StdOutOutput], MyRecord[StdErrOutput])
  GenericRecords[A, B] = (MyRecord[A], MyRecord[B])
  NamedRecords = tuple[first, second: MyRecord[StdErrOutput]]
  SingleRecord = (MyRecord[StdOutOutput],)

template initLogRecord*(r: var MyRecord, lvl: LogLevel,
                        topics: string, name: string) =
  r.line = "[" & $lvl & "] " & name

template setProperty*(r: var MyRecord, key: string, val: auto) =
  r.line.add " " & key & "=" & $val

template flushRecord*(r: var MyRecord) =
  r.output.append r.line, "\n"
  r.output.flushOutput

customLogStream inlineStream[(MyRecord[StdOutOutput], MyRecord[StdOutOutput])]
customLogStream aliasStream[Records]
customLogStream genericAliasStream[GenericRecords[StdErrOutput, StdOutOutput]]
customLogStream namedStream[NamedRecords]
customLogStream singleInlineStream[(MyRecord[StdErrOutput],)]
customLogStream singleAliasStream[SingleRecord]
customLogStream sharedAliasStream[Records]
customLogStream aliasedStream[(MyRecord[StdOutOutput], MyRecord[StdErrOutput])]
customLogStream unnamedStream[(MyRecord[StdErrOutput], MyRecord[StdErrOutput])]

inlineStream.info "inline tuple", a = 1
aliasStream.info "tuple alias", a = 2
genericAliasStream.info "generic tuple alias", a = 3
namedStream.info "named tuple", a = 4
singleInlineStream.info "inline 1-tuple", a = 5
singleAliasStream.info "1-tuple alias", a = 6
sharedAliasStream.info "shared tuple alias", a = 7
aliasedStream.info "aliased inline tuple", a = 8
unnamedStream.info "unnamed tuple", a = 9
