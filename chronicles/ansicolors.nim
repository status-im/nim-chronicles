from std/terminal import ansiResetCode, ForegroundColor, Style

from faststreams/outputs import write, OutputStream
from faststreams/textio import writeText

export ForegroundColor, Style, write, writeText, OutputStream

const stylePrefix = "\e["

template writeStyle*(output: OutputStream, style: int) =
  output.write(stylePrefix)
  output.writeText(style)
  output.write("m")

template writeStyle*(output: OutputStream, style: Style) =
  writeStyle(output, style.int)

template writeStyleReset*(output: OutputStream) =
  output.write(ansiResetCode)

template writeFgColor*(output: OutputStream, fg: ForegroundColor, bright = false) =
  var style = ord(fg)
  if bright:
    inc(style, 60)
  writeStyle(output, style)

