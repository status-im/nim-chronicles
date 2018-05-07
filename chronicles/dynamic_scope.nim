import
  macros, log_output, scope_helpers, options, dynamic_scope_types

proc appenderIMPL[LogRecord, PropertyType](log: var LogRecord,
                                           keyValuePair: ptr ScopeBindingBase[LogRecord]) =
  type ActualType = ptr ScopeBinding[LogRecord, PropertyType]
  # XXX: The use of `cast` here shouldn't be necessary. This is a normal explicit upcast.
  let v = cast[ActualType](keyValuePair)
  log.setProperty v.name, v.value

proc logAllDynamicProperties*[LogRecord](log: var LogRecord) =
  # This proc is intended for internal use only
  mixin tlsSlot

  var frame = tlsSlot(LogRecord)
  while frame != nil:
    for i in 0 ..< frame.bindingsCount:
      let binding = frame.bindings[i]
      binding.appender(log, binding)
    frame = frame.prev

proc makeScopeBinding[T](LogRecord: typedesc,
                         name: string,
                         value: T): ScopeBinding[LogRecord, T] =
  result.name = name
  result.appender = appenderIMPL[LogRecord, T]
  result.value = value

macro dynamicLogScopeIMPL*(recordType: typedesc,
                           lexicalScopes: typed,
                           args: varargs[untyped]): untyped =
  # XXX: open question: should we support overriding of dynamic props
  # inside inner scopes. This will have some run-time overhead.
  let body = args[^1]
  args.del(args.len - 1)

  if body.kind != nnkStmtList:
    error "dynamicLogScope expects a block", body

  var
    makeScopeBinding = bindSym"makeScopeBinding"
    bindingsVars = newTree(nnkStmtList)
    bindingsArray = newTree(nnkBracket)
    bindingsArraySym = genSym(nskLet, "bindings")

  for name, value in assignments(args):
    var bindingVar = genSym(nskLet, name)

    bindingsVars.add quote do:
      let `bindingVar` = `makeScopeBinding`(`recordType`, `name`, `value`)

    bindingsArray.add newCall("unsafeAddr", bindingVar)

  let totalBindingVars = bindingsVars.len

  result = quote:
    var prevBindingFrame = tlsSlot(`recordType`)

    try:
      # All of the dynamic binding pairs are placed on the stack.
      `bindingsVars`

      # An array is created to hold pointers to them.
      # This works, because of the common base type `ScopeBindingBase[LogRecord]`.
      let `bindingsArraySym` = `bindingsArray`

      # A `BindingFrame` object is also placed on the stack, holding
      # meta-data about the array and a link to the previous BindingFrame.
      let bindingFrame = BindingsFrame[`recordType`](
        prev: prevBindingFrame,
        bindings: cast[BindingsArray[`recordType`]](unsafeAddr `bindingsArraySym`),
        bindingsCount: `totalBindingVars`)

      # The address of the new BindingFrame is written to a TLS location.
      tlsSlot(`recordType`) = unsafeAddr(bindingFrame)

      # XXX: In resumable functions, we need help from the compiler to let us
      # intercept yields and resumes so we can restore our context.

      `body`

    finally:
      # After the scope block has been executed, we restore the previous
      # top BindingFrame.
      tlsSlot(`recordType`) = prevBindingFrame

