import ./[options, topics_registry]

when defined(js):
  type UncheckedArray[T] = seq[T]

template select(LogRecord, A, B: typedesc): typedesc =
  # When runtime filtering is enabled and we have more than one sink, we must
  # pass the "enabled-or-not" bitmask to all functions so that they can forward
  # to the sinks that are actually enabled
  # If this when is inlined in the type definition, it runs afould of some
  # evaluation order issue and selects the wrong type
  when LogRecord is tuple and runtimeFilteringEnabled: B else: A

type
  ScopeBindingBase*[LogRecord] = object of RootObj
    name*: string
    when (NimMajor, NimMinor) >= (2, 2):
      appender*: select(LogRecord, LogAppender[LogRecord], MultiLogAppender[LogRecord])
    else:
      appender*: pointer

  LogAppender*[LogRecord] =
    proc(x: var LogRecord, valueAddr: ptr ScopeBindingBase[LogRecord]) {.nimcall.}

  MultiLogAppender*[LogRecord] = proc(
    x: var LogRecord, valueAddr: ptr ScopeBindingBase[LogRecord], enabled: SinksBitmask
  ) {.nimcall.}

  ScopeBinding*[LogRecord, T] = object of ScopeBindingBase[LogRecord]
    value*: T

  BindingsArray*[LogRecord] = ptr UncheckedArray[ptr ScopeBindingBase[LogRecord]]

  BindingsFrame*[LogRecord] = object
    prev*: ptr BindingsFrame[LogRecord]
    bindings*: BindingsArray[LogRecord]
    bindingsCount*: int
