import
  typetraits

when defined(js):
  type UncheckedArray[T] = seq[T]

func arityFixed(T: typedesc): int {.compileTime.} =
  # TODO: File this as a Nim bug
  type TT = T
  arity(TT)

type
  LogAppender*[LogRecord] = proc(x: var LogRecord,
                                 valueAddr: ptr ScopeBindingBase[LogRecord])

  ScopeBindingBase*[LogRecord] = object of RootObj
    name*: string
    appenders*: array[arityFixed(LogRecord), LogAppender[LogRecord]]

  ScopeBinding*[LogRecord, T] = object of ScopeBindingBase[LogRecord]
    value*: T

  BindingsArray*[LogRecord] = ptr UncheckedArray[ptr ScopeBindingBase[LogRecord]]

  BindingsFrame*[LogRecord] = object
    prev*: ptr BindingsFrame[LogRecord]
    bindings*: BindingsArray[LogRecord]
    bindingsCount*: int

