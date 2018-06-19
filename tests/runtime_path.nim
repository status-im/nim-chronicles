import chronicles

discard defaultChroniclesStream.output.open("mylog.log", fmAppend)

info "log record", prop = 10

