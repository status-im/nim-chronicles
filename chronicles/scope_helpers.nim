import macros

iterator assignments*(n: NimNode, skip = 0): (string, NimNode) =
  # extract the assignment pairs from a block with assigments
  # or a call-site with keyword arguments.
  for i in skip ..< n.len:
    let child = n[i]
    if child.kind in {nnkAsgn, nnkExprEqExpr}:
      let name = $child[0]
      let value = child[1]
      yield (name, value)
    else:
      error "A scope definitions should consist only of key-value assignments"

