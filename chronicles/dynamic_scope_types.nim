when defined(js):
  type UncheckedArray[T] = seq[T]

type
  ScopeBindingBase*[LogRecord] = object of RootObj
    name*: string
    appender*: LogAppender[LogRecord]

  LogAppender*[LogRecord] = proc(x: var LogRecord,
                                 valueAddr: ptr ScopeBindingBase[LogRecord])

  ScopeBinding*[LogRecord, T] = object of ScopeBindingBase[LogRecord]
    value*: T

  BindingsArray*[LogRecord] = ptr UncheckedArray[ptr ScopeBindingBase[LogRecord]]

  BindingsFrame*[LogRecord] = object
    prev*: ptr BindingsFrame[LogRecord]
    bindings*: BindingsArray[LogRecord]
    bindingsCount*: int

