import
  macros, log_output, scope_helpers

type
  ScopeBindingBase = object of RootObj
    name: string
    appender: LogAppender

  LogAppender = proc(x: var LogOutput, valueAddr: ScopeBindingBase)

  ScopeBinding[T] = object of ScopeBindingBase
    value: T

  BindingsArray = ptr UncheckedArray[ptr ScopeBindingBase]

  BindingsFrame = object
    prev: ptr BindingsFrame
    bindings: BindingsArray
    bindingsCount: int

proc appenderIMPL[T](log: var LogOutput, valueAddr: ScopeBindingBase) =
  let v = ScopeBinding[T](valueAddr)
  log.setProperty v.name, v.value

var topBindingFrame {.threadvar.}: ptr BindingsFrame

proc chroniclesThreadInit* =
  # This must be called in each thread that is going to use logging
  topBindingFrame = nil

proc makeScopeBinding[T](name: string, value: T): ScopeBinding[T] =
  result.name = name
  result.appender = appenderIMPL[T]
  result.value = value

proc logAllDynamicProperties*(log: var LogOutput) =
  # This proc is intended for internal use only
  var frame = topBindingFrame
  while frame != nil:
    for i in 0 ..< frame.bindingsCount:
      let binding = frame.bindings[i]
      binding.appender(log, binding[])
    frame = frame.prev

template makeBindingsFrame(bindings: array): auto =
  BindingsFrame(prev: topBindingFrame,
                bindings: cast[BindingsArray](unsafeAddr bindings),
                bindingsCount: bindings.len)

macro dynamicLogScope*(args: varargs[untyped]): untyped =
  # XXX: open question: should we support overriding
  # of dynamic props inside inner scopes. This will
  # have some run-time overhead.
  let body = args[^1]
  args.del(args.len - 1)

  let
    makeScopeBinding = bindSym"makeScopeBinding"

  if body.kind != nnkStmtList:
    error "dynamicLogScope expects a block"

  var
    bindingsVars = newTree(nnkStmtList)
    bindingsArray = newTree(nnkBracket)
    bindingsArraySym = genSym(nskLet, "bindings")

  for name, value in assignments(args):
    var bindingVar = genSym(nskLet, name)

    bindingsVars.add quote do:
      let `bindingVar` = `makeScopeBinding`(`name`, `value`)

    bindingsArray.add newCall(newIdentNode("unsafeAddr"), bindingVar)

  let totalBindingVars = bindingsVars.len

  result = quote:
    let prevBindingFrame = topBindingFrame
    try:
      `bindingsVars`
      let `bindingsArraySym` = `bindingsArray`
      let bindingFrame = makeBindingsFrame(`bindingsArraySym`)
      topBindingFrame = unsafeAddr bindingFrame
      `body`
    finally:
      topBindingFrame = prevBindingFrame

chroniclesThreadInit()

