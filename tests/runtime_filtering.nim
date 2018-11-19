import chronicles

logScope:
  topics = "main"

proc foo =
  logScope:
    topics = "main foo"

  info "from foo"

proc bar =
  logScope:
    topics = "main bar"

  info "from bar"

echo "> start by printing both:"

foo()
bar()

echo "> disabling main, both should be omitted:"
echo setTopicState("main", Disabled)

foo()
bar()

echo "> set foo to required, only foo should be printed:"
echo setTopicState("main", Normal)
echo setTopicState("foo", Required)

foo()
bar()

echo "> set bar to enabled, only bar should be printed:"
echo setTopicState("foo", Normal)
echo setTopicState("bar", Enabled)

foo()
bar()

echo "> disable main again, both should be omitted:"
echo setTopicState("main", Disabled)

foo()
bar()

echo "> try a wrong call to setTopicState, disable bar and print out only foo:"
echo setTopicState("main", Required)
echo setTopicState("baz", Required)
echo setTopicState("bar", Disabled)

foo()
bar()

echo "> restore everything to normal, both should print:"
echo setTopicState("main", Normal)
echo setTopicState("foo", Normal)
echo setTopicState("bar", Normal)

foo()
bar()

echo "> set main to required WARN, none should print:"
echo setTopicState("main", Required, WARN)
echo setTopicState("foo", Normal)
echo setTopicState("bar", Normal)

foo()
bar()

echo "> set foo to INFO, bar and main to WARN, foo should print:"
echo setTopicState("main", Normal, WARN)
echo setTopicState("foo", Normal, INFO)
echo setTopicState("bar", Normal, WARN)

foo()
bar()

echo "> set global LogLevel to WARN, set main and foo to INFO, both should print:"
setLogLevel(WARN)
echo setTopicState("main", Normal, INFO)
echo setTopicState("foo", Normal, INFO)
echo setTopicState("bar", Normal)

foo()
bar()
