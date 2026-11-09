# zsh: a card for slow commands

A card when a command in your shell ran 10 seconds or more, only when you are not watching that terminal.

For: zsh users who start long jobs and look away. No `drip run` in front of the command.

## How it works

The block is shell code for `~/.zshrc`. It notes when each command starts. When the prompt comes
back it compares the time with a threshold in the shell itself, so a fast command never starts
drip. Only a slow one does, through `drip __finished`, which shows the card unless you are watching
that terminal. The card is the one `drip run` shows: the command, its status and its time.

The block leaves out commands that take over the terminal or wait for you in it, such as editors,
pagers, `ssh`, REPLs and the coding agents. It is silent where drip is missing, and where
`DRIP_HOOK=off`.

## Install

Paste this at the end of `~/.zshrc` (`$ZDOTDIR/.zshrc` if you set `ZDOTDIR`), then run `exec zsh`:

```zsh
# >>> drip: a card when a slow command finishes >>>
# From the drip recipe zsh-slow-commands. Delete this block to remove it.
# A command that runs 10 seconds or more shows a card when it ends, unless you are
# watching this terminal. No drip runs for a faster command.
#   DRIP_SLOW_AFTER   seconds a command must run for a card; 0 turns the cards off, and
#                     anything but a number leaves them off
#   DRIP_SLOW_IGNORE  more commands to leave out, space-separated, besides the editors, pagers,
#                     ssh and REPLs named below
# Silent where drip is missing, and where DRIP_HOOK=off.
if zmodload zsh/datetime 2>/dev/null && autoload -Uz add-zsh-hook 2>/dev/null; then
  typeset -g __drip_command __drip_expanded
  typeset -gF __drip_start
  typeset -ga __drip_ignore=(
    vim vi nvim view nano pico micro emacs hx kak less more most man info bat tail watch ssh
    mosh telnet sftp ftp nc screen tmux zellij herdr top htop btop glances nvtop python
    python3 node deno bun irb pry ipython lua ghci psql mysql sqlite3 redis-cli mongosh gdb
    lldb claude codex gemini aider opencode fzf nnn lf ranger yazi mc tig lazygit k9s fg bg su
    zsh bash fish sh drip
  )

  # Each function sets the shell's options to zsh's own for its run, so setopt in your rc
  # file (globsubst, nounset, shwordsplit) cannot change what they do.
  __drip_preexec() {
    emulate -L zsh
    __drip_command=$1
    __drip_expanded=$3
    __drip_start=$EPOCHREALTIME
  }

  # Whether the command line starts a command in the ignore list, past any assignments,
  # sudo and the like.
  __drip_ignored() {
    emulate -L zsh
    local word
    local -a ignore=($__drip_ignore ${=DRIP_SLOW_IGNORE-})
    for word in ${(z)1}; do
      case $word in
        *=* | -* | sudo | command | builtin | exec | env | nocorrect | noglob | nohup | time) continue ;;
      esac
      word=${${(Q)word}:t}
      (( ${ignore[(Ie)$word]} ))
      return
    done
    return 1
  }

  __drip_precmd() {
    local code=$?
    emulate -L zsh
    [[ -n $__drip_command ]] || return $code
    local command=$__drip_command expanded=$__drip_expanded
    __drip_command=
    local seconds=$(( EPOCHREALTIME - __drip_start ))
    local after=${DRIP_SLOW_AFTER:-10}
    [[ $after == <->(|.<->) ]] || return $code
    (( after > 0 && seconds >= after )) || return $code
    [[ ${DRIP_HOOK-} != off ]] || return $code
    (( $+commands[drip] )) || return $code
    __drip_ignored $expanded && return $code
    command drip __finished --status $code --seconds $seconds -- "$command" >/dev/null 2>&1 &!
    return $code
  }

  add-zsh-hook preexec __drip_preexec
  add-zsh-hook precmd __drip_precmd
fi
# <<< drip <<<
```

## Change it

- **The threshold.** Set `DRIP_SLOW_AFTER` in your environment to the number of seconds a command must run for a card.
  `export DRIP_SLOW_AFTER=30` in your `~/.zshrc` is one way. `0` turns the
  cards off, and so does a value that is not a number.
- **Commands to leave out.** Set `DRIP_SLOW_IGNORE` to more command names, separated by spaces, such
  as `export DRIP_SLOW_IGNORE="make watch"`. Or edit the `__drip_ignore` list in the block.
- **No cards from one shell.** Run `DRIP_HOOK=off zsh`.
- **Watching.** `when_focused` and `away_after` in the [config](../../docs/config.md) decide when
  you count as watching.
