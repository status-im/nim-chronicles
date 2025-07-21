## Module that separately can be imported by projects wanting to provide custom
## chronicles formatting for their types without importing the full chronicles
## library.

import std/strformat, stew/shims/macros

template chroniclesFormatItIMPL*(value: auto): auto =
  # By default, values are passed as-is to the log output
  value

template formatIt*(T: type, body: untyped) {.dirty.} =
  template chroniclesFormatItIMPL*(it: T): auto =
    body

# enabled: SinksBitMask
template chroniclesExpandItIMPL*[RecordType: tuple](
    record: RecordType, field: static string, value: auto, enabled: auto
) =
  mixin setProperty, chroniclesFormatItIMPL
  setProperty(record, field, chroniclesFormatItIMPL(value), enabled)

template chroniclesExpandItIMPL*[RecordType](
    record: RecordType, field: static string, value: auto
) =
  mixin setProperty, chroniclesFormatItIMPL
  setProperty(record, field, chroniclesFormatItIMPL(value))

macro expandIt*(T: type, expandedProps: untyped): untyped =
  let
    chroniclesFormatItIMPL = bindSym("chroniclesFormatItIMPL", brForceOpen)
    record = ident "record"
    it = ident "it"
    it_name = ident "it_name"
    enabled = ident "enabled"
    setPropertyTupleCalls = newStmtList()
    setPropertyCalls = newStmtList()

  for prop in expandedProps:
    if prop.kind != nnkAsgn:
      error "An `expandIt` definition should consist only of key-value assignments",
        prop

    var key = prop[0]
    let value = prop[1]
    case key.kind
    of nnkAccQuoted:
      proc toStrLit(n: NimNode): NimNode =
        let nAsStr = $n
        if nAsStr == "it":
          it_name
        else:
          newLit(nAsStr)

      if key.len < 2:
        key = key.toStrLit
      else:
        var concatCall = infix(key[0].toStrLit, "&", key[1].toStrLit)
        for i in 2 ..< key.len:
          concatCall = infix(concatCall, "&", key[i].toStrLit)
        key = newTree(nnkStaticExpr, concatCall)
    of nnkIdent, nnkSym:
      key = newLit($key)
    else:
      error &"Unexpected AST kind for an `expandIt` key: {key.kind} ", key

    setPropertyCalls.add newCall(
      "setProperty", record, key, newCall(chroniclesFormatItIMPL, value)
    )
    setPropertyTupleCalls.add newCall(
      "setProperty", record, key, newCall(chroniclesFormatItIMPL, value), enabled
    )

  # Both single- and multisink expanders are added here - the tradeoff would be
  # to import ./options and check if runtime filtering is enabled and skip the
  # latter if not
  result = quote:
    template chroniclesExpandItIMPL*[RecordType: tuple](
        `record`: RecordType, `it_name`: static string, `it`: `T`, `enabled`: auto
    ) =
      mixin setProperty, chroniclesFormatItIMPL
      `setPropertyTupleCalls`

    template chroniclesExpandItIMPL*(
        `record`: auto, `it_name`: static string, `it`: `T`
    ) =
      mixin setProperty, chroniclesFormatItIMPL
      `setPropertyCalls`

  when defined(debugLogImpl):
    echo result.repr
