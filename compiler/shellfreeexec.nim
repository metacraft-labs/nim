## Running the external commands the compiler builds without a shell.
##
## The compiler builds every C compiler, assembler, linker and `--run`
## command as ONE string, each argument quoted with `quoteShell`, and on
## POSIX it ran that string through the system shell: `osproc.execCmd` is
## libc's `system`, and `osproc.execProcesses` and `execCmdEx` add
## `poEvalCommand`, so both start `/bin/sh -c <command>`.
##
## A command made only of plain and quoted words means the same thing to
## the shell as the argv those words spell, so for such a command the shell
## adds nothing but one more program on the path of every compile: the
## machine's `/bin/sh`, its C library and whatever libraries it links. A
## build tool that records what a compile reads (a sandbox, a filesystem
## monitor, a hermetic build system) then records the host's shell as an
## input of every compile, and a compile recorded on one machine is not
## the same compile on a machine whose `/bin/sh` is another program (a
## NixOS `/bin/sh` is an interactive bash with readline; a Debian one is
## dash).
##
## `plainCommandArgv` splits a command into the argv the shell would have
## executed when, and only when, the command uses nothing the shell would
## interpret: no parameter or command substitution, no redirection, pipe,
## list, glob, tilde, comment, assignment prefix, reserved word, builtin or
## job specification.
## Any such command keeps going to the shell (`commandArgv` returns
## `@["/bin/sh", "-c", cmd]`, exactly what `poEvalCommand` starts), so no
## command changes meaning. The rules are those of the POSIX Shell Command
## Language, "Token Recognition" and "Quote Removal":
## https://pubs.opengroup.org/onlinepubs/9799919799/utilities/V3_chap02.html
##
## Windows is unchanged: there `execCmd` and `poEvalCommand` start the
## command line with `CreateProcess`, with no shell in between.

import std/[osproc, streams, strutils]

when defined(nimPreviewSlimSystem):
  import std/syncio

const
  PlainWordChars = {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.', '/', ':',
                    ',', '+', '%', '@', '=', '^'}
    ## Characters that stand for themselves, unquoted, in every POSIX shell
    ## (bash included: no brace, tilde or history expansion starts with
    ## one). `=` is plain in an argument; in the first word it would make an
    ## assignment, which `plainCommandArgv` refuses separately.
  ShellOnlyNames = ["!", "{", "}", "[[", "]]", "case", "do", "done", "elif",
    "else", "esac", "fi", "for", "function", "if", "in", "select", "then",
    "time", "until", "while",
    # Special and regular built-ins: a shell runs these itself, and some
    # have no program of that name at all.
    ".", ":", "[", "alias", "bg", "bind", "break", "builtin", "caller", "cd",
    "command", "compgen", "complete", "compopt", "continue", "coproc",
    "declare", "dirs", "disown", "echo", "enable", "eval", "exec", "exit",
    "export", "false", "fc", "fg", "getopts", "hash", "help", "history",
    "jobs", "kill", "let", "local", "logout", "mapfile", "newgrp", "popd",
    "printf", "pushd", "pwd", "read", "readarray", "readonly", "return",
    "set", "shift", "shopt", "source", "suspend", "test", "times", "trap",
    "true", "type", "typeset", "ulimit", "umask", "unalias", "unset", "wait",
    # Built-ins of other shells a system may install as `/bin/sh`: dash and
    # BusyBox ash (`chdir`), and ksh and zsh in sh emulation.
    "autoload", "bye", "chdir", "disable", "emulate", "end", "float",
    "foreach", "functions", "integer", "limit", "nameref", "nocorrect",
    "noglob", "print", "r", "rehash", "repeat", "sched", "setopt",
    "unfunction", "unhash", "unlimit", "unsetopt", "vared", "whence", "where",
    "which", "zmodload"]
  useShPath {.strdefine.} =
    when defined(android): "/system/bin/sh" else: "/bin/sh"
    ## What `poEvalCommand` starts: the same define, and the same default,
    ## as osproc's, so a compiler built with `-d:useShPath=...` hands a
    ## refused command to the shell it names.
  ShellPath = useShPath

proc plainCommandArgv*(cmd: string): seq[string] =
  ## The argv the shell would execute for `cmd`, or `@[]` when `cmd` needs
  ## the shell: it uses a character, quoting form or word the shell would
  ## interpret (see the module documentation), or it is empty.
  ##
  ## Words are separated by spaces and tabs (a newline separates commands,
  ## so it needs the shell). A single-quoted string is literal; a
  ## double-quoted one is literal when it holds no `$`, backquote or
  ## backslash; a backslash outside quotes makes the next character literal.
  ## Adjacent unquoted and quoted parts make one word, and `''` is an empty
  ## word, as in the shell.
  var words: seq[string] = @[]
  var word = ""
  var inWord = false
  var i = 0
  while i < cmd.len:
    let c = cmd[i]
    case c
    of ' ', '\t':
      if inWord:
        words.add word
        word = ""
        inWord = false
      inc i
    of '\'':
      let close = cmd.find('\'', i + 1)
      if close < 0: return @[]
      word.add cmd.substr(i + 1, close - 1)
      inWord = true
      i = close + 1
    of '"':
      var j = i + 1
      while j < cmd.len and cmd[j] != '"':
        if cmd[j] in {'$', '`', '\\'}: return @[]
        word.add cmd[j]
        inc j
      if j >= cmd.len: return @[]
      inWord = true
      i = j + 1
    of '\\':
      if i + 1 >= cmd.len or cmd[i + 1] == '\n': return @[]
      word.add cmd[i + 1]
      inWord = true
      i += 2
    else:
      if c notin PlainWordChars: return @[]
      # An unquoted `=` in the first word makes it an assignment.
      if c == '=' and words.len == 0: return @[]
      word.add c
      inWord = true
      inc i
  if inWord:
    words.add word
  if words.len == 0 or words[0].len == 0 or words[0] in ShellOnlyNames:
    return @[]
  # bash runs a first word starting with `%` as a job specification (`fg`).
  if words[0][0] == '%':
    return @[]
  result = words

proc commandArgv*(cmd: string): seq[string] =
  ## What runs `cmd`: its own argv when it needs no shell, otherwise the
  ## shell with `cmd` as its script, as `poEvalCommand` would start it.
  result = plainCommandArgv(cmd)
  if result.len == 0:
    result = @[ShellPath, "-c", cmd]

proc execCommand*(cmd: string): int =
  ## `osproc.execCmd`, without the shell when `cmd` does not need one. The
  ## child inherits the standard streams; the result is its exit code, or
  ## 128 plus the signal that ended it, as the shell reports one. A program
  ## that cannot be started is reported on stderr with exit code 127, as the
  ## shell reports a command it cannot find.
  when defined(windows):
    result = execCmd(cmd)
  else:
    let argv = plainCommandArgv(cmd)
    if argv.len == 0:
      return execCmd(cmd)
    var p: Process = nil
    try:
      p = startProcess(argv[0], args = argv.toOpenArray(1, argv.high),
        options = {poUsePath, poParentStreams})
    except OSError as e:
      stderr.writeLine(argv[0] & ": " & e.msg)
      return 127
    try:
      result = waitForExit(p)
    finally:
      close(p)

proc execCommandEx*(cmd: string): tuple[output: string, exitCode: int] =
  ## `osproc.execCmdEx` with its default options (stderr merged into the
  ## captured output, the program searched for on `PATH`), without the shell
  ## when `cmd` does not need one.
  when defined(windows):
    result = execCmdEx(cmd)
  else:
    result = ("", 0)
    let argv = commandArgv(cmd)
    let p = startProcess(argv[0], args = argv.toOpenArray(1, argv.high),
      options = {poStdErrToStdOut, poUsePath})
    try:
      p.inputStream.close()
      result.output = p.outputStream.readAll()
      result.exitCode = waitForExit(p)
    finally:
      close(p)

proc execCommandsInParallel*(cmds: openArray[string];
    options: set[ProcessOption]; n: int;
    beforeRunEvent: proc(idx: int) = nil;
    afterRunEvent: proc(idx: int, p: Process) = nil): int =
  ## `osproc.execProcesses`, with each command that does not need the shell
  ## started without one (`execArgvProcesses`).
  when defined(windows) or not declared(execArgvProcesses):
    # Also when the compiler is built against a standard library older than
    # `execArgvProcesses` (bootstrapping with an installed Nim): every
    # command then goes to the shell, as before.
    result = execProcesses(cmds, options, n, beforeRunEvent, afterRunEvent)
  else:
    var argvs = newSeq[seq[string]](cmds.len)
    for i, cmd in cmds:
      argvs[i] = commandArgv(cmd)
    result = execArgvProcesses(argvs, options, n, beforeRunEvent,
      afterRunEvent)
