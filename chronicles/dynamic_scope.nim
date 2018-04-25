import
  macros, log_output, scope_helpers

type
  ScopeBindingBase = ref object of RootObj
    name: string
    appender: LogAppender

  LogAppender = proc(x: var LogOutput, valueAddr: ScopeBindingBase)

  ScopeBinding[T] = ref object of ScopeBindingBase
    value: T

proc appenderIMPL[T](log: var LogOutput, valueAddr: ScopeBindingBase) =
  let v = ScopeBinding[T](valueAddr)
  log.setProperty v.name, v.value

var dynamicProperties {.threadvar.}: seq[ScopeBindingBase]

proc chroniclesThreadInit* =
  # This must be called in each thread that is going to use logging
  newSeq(dynamicProperties, 0)

proc addDynamicProp[T](name: string, value: T) =
  dynamicProperties.add ScopeBinding[T](name: name,
                                        value: value,
                                        appender: appenderIMPL[T])

proc logAllDynamicProperties*(log: var LogOutput) =
  # This proc is intended for internal use only
  for p in dynamicProperties: p.appender(log, p)

macro dynamicLogScope*(args: varargs[untyped]): untyped =
  # XXX: open question: should we support overriding
  # of dynamic props inside inner scopes. This will
  # have some run-time overhead.
  let body = args[^1]
  args.del(args.len - 1)

  if body.kind != nnkStmtList:
    error "dynamicLogScope expects a block"

  let addDynamicProp = bindSym"addDynamicProp"

  var setProps = newTree(nnkStmtList)
  for name, value in assignments(args):
    setProps.add newCall(addDynamicProp, newLit(name), value)

  result = quote:
    var currentDynamicScopesEntries = dynamicProperties.len
    try:
      `setProps`
      `body`
    finally:
      dynamicProperties.setLen currentDynamicScopesEntries

chroniclesThreadInit()

