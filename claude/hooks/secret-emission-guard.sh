#!/usr/bin/env bash
#
# claude/hooks/secret-emission-guard.sh
# =====================================
#
# Claude Code PreToolUse hook (matcher: Bash). Refuses the handful of commands
# that PRINT credentials, unless their output is piped through
# scripts/redact-secrets.sh.
#
# Why: on 2026-09-01 both of this machine's live GitHub tokens were found in
# plaintext in five session transcripts, two written days earlier. Transcripts
# are conversation context, so the values had left the host as well. No single
# dramatic mistake — just ordinary diagnostics (`ps` on a process started with
# `-e GH_TOKEN=…`, a `printf` of `$GH_TOKEN`, a bare `gh auth token`), and
# everything printed is recorded. Rotation does not fix that: it is manual,
# browser-only for GitHub, and undone by the next capture.
#
# DENY, not ask. This fires on a small set of command shapes an agent runs while
# investigating, and the remedy is mechanical (add ` | redact-secrets`), so a
# prompt would only train the human to click through. `ask` would also make the
# guard the most annoying thing on the machine, and an annoying guard gets
# deleted — which is the failure mode every checker in this repo is written
# against.
#
# FAIL OPEN. Any error here — bad JSON, missing jq, an unreadable payload —
# allows the command. A hook that blocks the shell when it breaks is a hook that
# gets disabled wholesale, taking its protection with it. The cost of failing
# open is a missed redaction; the cost of failing closed is no guard at all.
#
# SCOPE, stated plainly so nobody mistakes it for a boundary: this stops the
# CAPTURES THAT KEEP HAPPENING, not a determined leak. Any command can print a
# secret, and this knows about six shapes. It is a papercut guard, and the real
# fixes are shorter-lived credentials and narrower scopes.
#
# Contract: reads the hook payload on stdin, writes a permissionDecision JSON on
# stdout. https://docs.claude.com/en/docs/claude-code/hooks

set -uo pipefail

allow() { exit 0; }   # silence == allow

command -v jq >/dev/null 2>&1 || allow

payload="$(cat)" || allow
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)" || allow
[[ -n "$cmd" ]] || allow

# Already routed through the redactor (by name, so either the repo path or the
# ~/.local/bin symlink counts) — nothing to do.
[[ "$cmd" == *redact-secrets* ]] && allow

# Strip quoted strings before matching, so a command that merely MENTIONS one of
# these shapes in a message or a grep pattern is not refused. Without this the
# guard blocks `git commit -m "stop ps from leaking"`, which is the kind of
# false positive that gets a hook turned off.
probe="$(printf '%s' "$cmd" | sed -E "s/'[^']*'//g; s/\"[^\"]*\"//g")"

# --- credential-file reads -------------------------------------------------
#
# `cmd_segments` emits one command segment per line, splitting only where the
# SHELL would: a newline, `;`, `&&` or `||` that is not inside quotes. The
# credential-file rule then requires a filename and a reading verb to land in
# the SAME segment.
#
# Why segment at all: the rule used to test for the filename and for the verb
# independently over the whole command string, so it refused any compound
# command that named such a file anywhere and read some OTHER file anywhere --
# authoring documentation about ~/.gitconfig.local and then grepping the draft,
# for instance. That is group 2, the false positive that gets a hook deleted.
#
# Four decisions in here are load-bearing, and each is a row in
# scripts/test-secret-guard.sh:
#
#   QUOTES. A `;` or `|` inside a quoted script argument is data, not a
#   separator. `sed -n '1,5p;10p' <file>` and `grep -E 'a|b' <file>` are single
#   commands that dump the file; splitting on those characters tore the verb
#   away from the filename and allowed the read. So the scan tracks quote state
#   and only breaks outside it. An unbalanced quote makes the remainder count as
#   quoted, which merges segments rather than splitting them -- the direction
#   that denies, not the one that leaks.
#
#   PIPELINES ARE NOT SPLIT. A pipeline is one unit of data flow: the file named
#   in one stage is read by a verb in another, as in `echo <file> | xargs cat`.
#   Lone `&` is likewise left alone, so `2>&1` cannot break a segment apart.
#
#   COMPOUND KEYWORDS. A `;` or newline that merely introduces the `do` of a
#   loop is not a command boundary: `for f in <file>; do cat $f; done` names
#   the file in the header and reads it in the body, and splitting there tore
#   the two apart. Merging can only over-deny, but the keyword list is still
#   kept to `do` alone -- see SEG_MERGE_KEYWORDS below for what `then` costs.
#
#   NO HEREDOC STRIPPING. A heredoc body is data being written, and stripping it
#   would drop prose that names a credential file next to a verb. But a stripper
#   must guess where the body ends, and every wrong guess DELETES the rest of
#   the command from the rule's view: `<<-` with a tab-indented terminator, a
#   mismatched terminator, or a `<<` inside a quoted string each swallowed a
#   following real read. Over-stripping leaks; not stripping costs one false
#   positive, on UNQUOTED heredoc prose. Quoted prose -- the usual shape when
#   generating code or docs -- is already fine, because the verb test runs on
#   the quote-stripped segment.
#
# Keywords that CONTINUE the command a `;` or a newline appears to end, so that
# separator is not a segment boundary. Used by the `';'` branch of cmd_segments.
#
# Deliberately just `do`, not every compound-command keyword, and that is a
# MEASURED narrowing rather than an oversight. The other candidates split three
# ways:
#
#   `then`/`else` cost a real false positive. `if [ -f <file> ]; then cat
#   README.md; fi` is an ordinary existence test whose body reads some OTHER
#   file, and merging the halves refuses it. The suite already asserts that the
#   `&&` spelling of that command is allowed (`test -f <file> && echo yes`); a
#   guard that refuses the `; then` spelling of a command it allows with `&&`
#   is the false positive this whole file is written against.
#
#   `fi`/`esac`/`done`/`in` buy nothing. An `if` or `case` BODY already denies
#   without any merging, because the filename and the verb both land after the
#   keyword and so already share a segment. Only a loop HEADER puts the
#   filename before the separator and the verb after it.
#
# Both halves of that are rows in scripts/test-secret-guard.sh rather than
# claims here, including the two that a wider list would break.
SEG_MERGE_KEYWORDS="do"

# Pure bash on purpose: no awk, no second dependency, and nothing that can fail
# to empty output and silently switch the rule off.
cmd_segments() {
  # Two statements on purpose: ${#s} in the same `local` as s= would be expanded
  # before s was assigned, leaving n empty -- the loop then never runs, every
  # segment vanishes and the rule silently allows everything. shellcheck SC2318.
  local s="$1"
  local n=${#s} i=0 ch nxt q="" out="" j w kw_end=-1

  # A pathological command is not worth a character loop. Emitting it whole
  # merges every segment, which can only over-deny. Newlines are flattened to
  # spaces first: `out` must carry a newline ONLY where a break is intended,
  # and the caller's `while read` would otherwise break on the raw ones.
  if (( n > 8192 )); then printf '%s\n' "${s//$'\n'/ }"; return 0; fi

  while (( i < n )); do
    ch="${s:i:1}"
    if [[ -n "$q" ]]; then
      # Single quotes take no escapes in sh; inside double quotes a backslash
      # protects the next character, including a closing quote.
      if [[ "$q" == '"' && "$ch" == \\ ]]; then
        # Backslash-newline inside double quotes is a line continuation: the
        # shell removes both characters and joins the lines. Emit nothing.
        if [[ "${s:i+1:1}" == $'\n' ]]; then (( i += 2 )); continue; fi
        out+="$ch"; (( i++ ))
        (( i < n )) && out+="${s:i:1}"
        (( i++ )); continue
      fi
      # A newline INSIDE quotes is data, exactly as a `;` inside quotes is --
      # a multi-line awk or sed script is one command. Emitting it verbatim
      # would let the caller's `while read` break the segment there and tear
      # the verb away from the filename, so it becomes a space.
      if [[ "$ch" == $'\n' ]]; then out+=' '; (( i++ )); continue; fi
      out+="$ch"
      [[ "$ch" == "$q" ]] && q=""
      (( i++ )); continue
    fi
    case "$ch" in
      "'"|'"') q="$ch"; out+="$ch" ;;
      \\)
        # Unquoted backslash-newline is a line continuation. The shell deletes
        # both characters, joining what follows onto this line -- possibly
        # mid-word, as in `ca\` + newline + `t file` -- so emit nothing rather
        # than a space, or the rejoined verb would no longer match.
        if [[ "${s:i+1:1}" == $'\n' ]]; then (( i += 2 )); continue; fi
        out+="$ch"; (( i++ )); (( i < n )) && out+="${s:i:1}" ;;
      ';'|$'\n')
        # A separator that merely introduces -- or merely follows -- a
        # compound-command KEYWORD is not a command boundary in any useful
        # sense. `for f in <file>; do cat $f; done` names the file in the loop
        # header and reads it in the body: one command, one dataflow, and
        # splitting at the `;` tore the verb away from the filename. Merging
        # instead can only ever over-deny, which is the safe direction.
        #
        # The word is taken WHOLE, up to whitespace or a shell metacharacter,
        # and compared whole. A prefix test would merge on `docker ps` and on
        # `do_something README.md`.
        j=$((i+1))
        while (( j < n )) && [[ "${s:j:1}" == [[:space:]] ]]; do (( j++ )); done
        # One BOUNDED substring, not a character loop. Scanning the next word
        # a character at a time doubled the cost of every separator-heavy
        # command -- measured 0.25s -> 0.61s of CPU on 400 separators -- and
        # this hook's timeout is 5s, where a timeout FAILS OPEN. 16 is far past
        # the longest keyword; a longer word is truncated, which can only fail
        # to match, never match something it should not.
        w="${s:j:16}"
        w="${w%%[[:space:]]*}"
        w="${w%%[;&|()<>]*}"
        if [[ " $SEG_MERGE_KEYWORDS " == *" $w "* ]]; then
          # Remember where the keyword ended, so the separator on its FAR side
          # merges too. A loop written over several lines has two separators,
          # not one --
          #     for f in <file>
          #     do
          #       cat $f
          #     done
          # -- and merging only the first still leaves the header in one
          # segment and the body in the next, which is the miss this change
          # exists to close, in the spelling people actually write.
          out+=' '; kw_end=$(( j + ${#w} ))
        elif (( kw_end >= 0 && i >= kw_end )) \
             && [[ "${s:kw_end:i-kw_end}" =~ ^[[:space:]]*$ ]]; then
          # One-shot, and it fires only for a keyword we ALREADY merged into --
          # i.e. one that was itself introduced by a separator, which is what
          # makes it a loop keyword rather than the word `do` in somebody's
          # prose. A plain look-behind would merge `echo do` with the next
          # command.
          out+=' '; kw_end=-1
        else
          out+=$'\n'; kw_end=-1
        fi
        ;;
      '&'|'|')
        nxt="${s:i+1:1}"
        # `&&` and `||` separate commands; a single `|` or `&` does not.
        if [[ "$nxt" == "$ch" ]]; then out+=$'\n'; (( i++ )); else out+="$ch"; fi ;;
      *) out+="$ch" ;;
    esac
    (( i++ ))
  done
  printf '%s\n' "$out"
}


# --- secret-bearing variable expansions ------------------------------------
#
# Every rule above matches a command SHAPE. None is keyed on the variable being
# expanded, so `echo "$GH_TOKEN"` was allowed -- and on 2026-09-06 a line of
# exactly that family printed a live OAuth token into a session transcript. It
# was the fourth such capture in six days.
#
# Two things have to be right, or the rule never fires and never stops firing:
#
#   MATCH ON THE RIGHT TEXT. $probe has ALL quoted strings stripped, and a leak
#   is almost always inside quotes, so a case appended to the block above could
#   never have matched. The raw command is wrong in the other direction: single
#   quotes SUPPRESS expansion, so `echo 'see $GH_TOKEN'` prints the name rather
#   than the value and refusing it is a false positive. The name is therefore
#   looked for with single-quoted spans removed and double-quoted ones KEPT --
#   neither $cmd nor $probe.
#
#   TELL THE REPORTING FORMS APART FROM THE LEAKING ONES. `${NAME:-unset}` and
#   `${NAME-unset}` expand to the VALUE whenever the variable is set, which is
#   the exact construction that leaked. `${#NAME}` and `${NAME:+<literal>}` do
#   not, and they are what CLAUDE.md prescribes for reporting set/unset -- so
#   denying them would leave no way to report it at all, and a guard with no
#   permitted alternative is one people route around.
#
# Known-uncovered, deliberately: an interpreter handed the expansion as a
# string. `bash -c 'echo $GH_TOKEN'` expands in the CHILD, where single quotes
# no longer suppress anything -- and the same single-quote rule that stops the
# false positive above is what hides it. Same class as the shapes DO-597 names.

# 0 if $1 names a variable that holds a credential.
secret_var_name() {
  case "$1" in
    GH_TOKEN|GITHUB_TOKEN|GITHUB_PERSONAL_ACCESS_TOKEN) return 0 ;;
    ANTHROPIC_API_KEY|LINEAR_API_KEY|NOTION_PAT)        return 0 ;;
    *_TOKEN|*_API_KEY|*_APIKEY|*_SECRET|*_PASSWORD|*_PASSWD|*_PAT) return 0 ;;
  esac
  return 1
}

SVE_NAME=""
# 0 if $1 contains an expansion that yields the VALUE of such a variable.
secret_expansion_in() {
  local rest="$1" brace name consumed tail
  while [[ "$rest" =~ \$(\{?)([A-Za-z_][A-Za-z0-9_]*) ]]; do
    brace="${BASH_REMATCH[1]}"; name="${BASH_REMATCH[2]}"
    # Consume `$`, the optional brace and the name -- NOT the character after
    # it, which may itself open the next expansion: in `$A$B`, eating one more
    # character would swallow the `$` of `$B`. This is exactly BASH_REMATCH[0],
    # and it is never empty, so `rest` strictly shrinks and the loop ends.
    consumed="\$${brace}${name}"
    tail="${rest#*"$consumed"}"
    rest="$tail"
    secret_var_name "$name" || continue
    # A bare `$NAME` expands to the value.
    if [[ -z "$brace" ]]; then SVE_NAME="$name"; return 0; fi
    case "$tail" in
      '+'*|':+'*)
        # ${NAME:+ALT} expands to ALT and never to the value, so it is safe.
        # That is the form CLAUDE.md prescribes for reporting set/unset --
        # `echo "tok: ${GH_TOKEN:+set (${#GH_TOKEN} chars)}"` -- and denying it
        # would leave no way to report it at all.
        #
        # ALT needs no handling of its own, which is worth stating because the
        # obvious implementation recurses into it. The scan continues through
        # `rest`, and `rest` still CONTAINS ALT, so an expansion of the value
        # inside the alternate is found by the next turn of this loop --
        # `${NAME:+${NAME}}` denies on the inner one. A recursive call as well
        # was redundant, and a mutant removing it could not be killed.
        ;;
      *)
        # Everything else -- ${NAME}, ${NAME:-x}, ${NAME-x}, ${NAME:=x},
        # ${NAME?x}, ${NAME#p}, ${NAME:0:4} -- yields the value or a FRAGMENT
        # of it, and a fragment of a credential is a credential.
        SVE_NAME="$name"; return 0 ;;
    esac
  done
  return 1
}

SVE_WHY=""
secret_var_expansion() {
  local seg exp stripped verb safe

  cmd_segments_ensure || return 1
  while IFS= read -r seg || [[ -n "$seg" ]]; do
    # No `$`, no expansion. The strip fork below is gated on this.
    [[ "$seg" == *'$'* ]] || continue

    # Condition one: the NAME, on the single-quote-stripped segment. A
    # backslash-escaped `$` goes too: inside double quotes `\$NAME` prints the
    # NAME, which is how you write about the variable rather than read it.
    exp="$(printf '%s' "$seg" | sed -E "s/'[^']*'//g; s/\\\\[$]//g")"
    secret_expansion_in "$exp" || continue

    # Condition two: a PRINTING verb, on the quote-stripped segment -- the same
    # split the credential-file rule above uses, and for the same reason. An
    # expansion is not an emission: `[[ -n "$GH_TOKEN" ]]`,
    # `export GH_TOKEN="$(gh auth token --user x)"` and
    # `curl -H "Authorization: Bearer $GH_TOKEN" ...` all expand the variable
    # and print nothing. This repo's own zsh/zshrc.herdr contains the first of
    # them, so a rule keyed on the expansion alone refuses ordinary work on the
    # very tree the guard lives in -- the false positive that costs the whole
    # guard.
    stripped="$(printf '%s' "$seg" | sed -E "s/'[^']*'//g; s/\"[^\"]*\"//g")"
    [[ "$stripped" =~ (^|[|;\&[:space:]])(echo|printf|print|cat|tee|logger)([[:space:]]|$) ]] || continue
    verb="${BASH_REMATCH[2]}"

    # Name the safe form in the message. The generic remedy below points at the
    # redactor, which is the wrong tool here: there is nothing to redact when
    # all you wanted was to say whether the variable is set.
    # shellcheck disable=SC2016  # this is the literal text of the remedy,
    # not an expansion to perform here
    safe='${'"$SVE_NAME"':+set (${#'"$SVE_NAME"'} chars)}'
    SVE_WHY="\`$verb\` expands \`\$$SVE_NAME\`, which holds a credential. Report it without printing it: \`echo \"$SVE_NAME: $safe\"\`. Note the redactor named below matches token SHAPES, so it is not a reliable remedy for an arbitrary variable"
    return 0
  done <<< "$CMD_SEGS"

  return 1
}

# cmd_segments is a character loop, so it is the most expensive thing in this
# file -- measured 0.33s of CPU on a 400-segment command. There are two rules
# that need segments now, and calling it once per rule DOUBLED that (0.33s ->
# 0.74s) for no change in what either rule sees. The hook's timeout is 5s and a
# timeout FAILS OPEN, so this is a correctness margin, not tidiness.
#
# Assign to a local and set the flag only on success: `VAR=$(cmd)` creates the
# variable even when cmd fails, so caching the assignment directly would record
# a FAILED run as a successful EMPTY one -- and an empty segment list reads as
# "this command has no segments", which allows everything.
CMD_SEGS=""
CMD_SEGS_CACHED=""
# POPULATES; it does not print. A function that printed the segments would have
# to be called as `< <(...)`, and process substitution runs it in a SUBSHELL --
# so the assignment below would be made in the child and lost, the cache would
# never be warm, and every rule would pay the full character loop again while
# looking memoised. Callers read $CMD_SEGS with a herestring instead.
cmd_segments_ensure() {
  local out
  [[ -n "$CMD_SEGS_CACHED" ]] && return 0
  # Assign to a local and set the flag only on success: `VAR=$(cmd)` creates
  # the variable even when cmd fails, so caching the assignment directly would
  # record a FAILED run as a successful EMPTY one -- and an empty segment list
  # reads as "this command has no segments", which allows everything.
  out="$(cmd_segments "$cmd")" || return 1
  CMD_SEGS="$out"; CMD_SEGS_CACHED=1
}

CFR_WHY=""
credential_file_read() {
  local seg stripped hit verb redir_re

  # `|| [[ -n $seg ]]` so a final segment with no trailing newline is still seen.
  cmd_segments_ensure || return 1
  while IFS= read -r seg || [[ -n "$seg" ]]; do
    [[ -n "$seg" ]] || continue

    # Path on the RAW segment: `cat "$HOME/.zshrc.local"` must still match, and
    # $stripped below cannot see a path that exists only inside quotes.
    [[ "$seg" =~ (\.zshrc\.local|\.gitconfig\.local|\.backup\.local|\.credentials\.json) ]] || continue
    hit="${BASH_REMATCH[1]}"

    # Verb on the QUOTE-STRIPPED segment: a message naming the file is not a read.
    stripped="$(printf '%s' "$seg" | sed -E "s/'[^']*'//g; s/\"[^\"]*\"//g")"

    # An input redirection feeds the file to whatever command is there, so it
    # needs no verb list at all -- and it is what four of the shapes DO-597
    # lists have in common: `tr -d x < <file>`, `tee < <file>`,
    # `mapfile -t a < <file>` and `while read ...; done < <file>`. Enumerating a
    # verb for each of those would be four entries that all mean "this file is
    # being read", which is exactly the endless-verb-list problem the issue
    # names. `<` and not `<<`: a heredoc is data being WRITTEN, and `<<` reads
    # nothing from the named file.
    # In a variable: an unquoted `<` inside [[ =~ ]] is parsed as a redirection
    # before the regex is ever seen, and `\<` does not escape it.
    redir_re='(^|[^<])[<][[:space:]]*[^<[:space:]]*(\.zshrc\.local|\.gitconfig\.local|\.backup\.local|\.credentials\.json)'
    if [[ "$stripped" =~ $redir_re ]]; then
      CFR_WHY="an input redirection from \`$hit\`, which holds credentials"
      return 0
    fi

    # Verbs that print a file's contents. `wc`, `ls`, `stat` and `readlink` are
    # deliberately absent: they report metadata, not content, and the suite has
    # rows asserting they stay allowed.
    [[ "$stripped" =~ (^|[|;\&\(\`[:space:]])(cat|tac|head|tail|less|more|bat|batcat|nl|od|xxd|strings|grep|egrep|fgrep|rg|sed|awk|source|cut|base64|paste|sort|uniq|rev|fold|expand|column|jq|diff|\.)([[:space:]]|$) ]] || continue
    verb="${BASH_REMATCH[2]}"

    CFR_WHY="\`$verb\` on \`$hit\`, which holds credentials"
    return 0
  done <<< "$CMD_SEGS"

  return 1
}

why=""
case "$probe" in
  # Prints a token to stdout. That is its entire purpose.
  *"gh auth token"*)                 why="\`gh auth token\` prints a credential" ;;
  *"gh auth status"*--show-token*)   why="\`gh auth status --show-token\` prints a credential" ;;
esac
if [[ -z "$why" ]]; then
  # Full command lines of other processes: /proc/<pid>/cmdline is world-readable
  # and routinely contains `-e VAR=<secret>` from whatever launched a daemon.
  # Narrow on purpose — `ps -o comm=` and `ps -p N` show no arguments and are
  # not matched.
  if [[ "$probe" =~ (^|[|;&[:space:]])ps([[:space:]]+-[A-Za-z]*[efl][A-Za-z]*|[[:space:]]+aux|[[:space:]]+-o[[:space:]]*[^|;&]*(args|cmd|command)) ]]; then
    why="\`ps\` with full command lines can show another process's secrets"
  elif [[ "$probe" =~ (^|[|;&[:space:]])pgrep([[:space:]]+-[A-Za-z]*a|[[:space:]]+--list-full) ]]; then
    why="\`pgrep -a\` prints full command lines"
  # A bare dump. `env VAR=x cmd` and `env -u VAR cmd` SET the environment for a
  # child and print nothing — they must not be caught, and are not.
  elif [[ "$probe" =~ (^|[|;&[:space:]])(env|printenv)[[:space:]]*($|[|;&]) ]]; then
    why="a bare \`${BASH_REMATCH[2]}\` dumps every variable, including exported tokens"
  elif [[ "$probe" == */proc/*cmdline* || "$probe" == */proc/*environ* ]]; then
    why="/proc command lines and environments contain other processes' secrets"
  # Reading a file that HOLDS credentials, which every rule above misses: they
  # all match a command that prints a secret it fetched, not one that prints a
  # file. CLAUDE.md's Security Rules send every secret on the machine to
  # ~/.zshrc.local, so this guard covered every emission shape except the
  # documented home of all of them. On 2026-09-07 a `tail -8 ~/.zshrc.local`,
  # run to find where to append a PATH line, put a live LINEAR_API_KEY and a
  # NOTION_PAT into a transcript. Same class as the incident that created this
  # hook; this rule is that gap closed.
  #
  # TWO conditions, and the split between them is load-bearing. Both are applied
  # per SEGMENT by credential_file_read above, which is where the details and the
  # quoting/pipeline/heredoc decisions are written down:
  #
  #   the PATH matches on the RAW segment, because the quote-stripped copy cannot
  #   see a path that exists only inside quotes -- and `cat "$HOME/.zshrc.local"`
  #   is the most natural way to write it.
  #
  #   the VERB matches on the quote-stripped segment, and both must hold.
  #   Path-alone on the raw command refuses `git commit -m "move flyctl out of
  #   zshrc.local"` -- a message merely NAMING the file -- which is precisely the
  #   false positive this file's header says costs the whole guard.
  #
  # Metadata-only commands (ls, stat, test -f, readlink) print no content and are
  # deliberately not verbs here. A python3 heredoc that opens the file is not
  # caught either: it prints nothing by default, and blocking it would refuse
  # ordinary edits to the very file people are told to put their secrets in.
  #
  # Known-uncovered. DO-597 chose option (a) -- add the reachable shapes and
  # NAME the rest here -- because option (b), enforcing on output rather than on
  # the command, is not available to a PreToolUse hook: it runs before the
  # command does, and a PostToolUse hook sees the output only after it has been
  # produced and recorded, which is too late to prevent the capture. The
  # output-side tool already exists and is scripts/redact-secrets.sh.
  #
  # So this list is the scope, stated rather than implied:
  #
  #   AN INTERPRETER HANDED THE PATH -- `python3 -c "print(open(F).read())"`,
  #   `perl -ne print F`, `node -e`. The read happens inside a language this
  #   hook does not parse. Matching the interpreter's NAME would refuse every
  #   ordinary edit to the very file people are told to keep secrets in.
  #
  #   `eval` OF A STRING CONTAINING THE READ. The verb is inside quotes, and the
  #   verb test runs on the quote-stripped segment precisely so that a message
  #   naming a file is not a read. The two cannot both be had.
  #
  #   A GLOB-REACHED PATH -- `cat ~/.zshrc.loca*`. The filename test is a fixed
  #   set of literals; making it a glob-matcher is how a filename test starts
  #   matching things nobody meant.
  #
  #   `$(< <file>)`, bash's read-a-file substitution, which has no verb at all.
  #
  # Command substitution itself IS caught: `echo $(cat <file>)` and the backtick
  # form differ from a plain read only in the character before the verb, so `(`
  # and a backtick are word boundaries in the verb pattern above.
  #
  #   caught BEFORE segmenting and no longer caught -- a deliberate reduction,
  #   not an oversight. Segmenting cannot follow data from one segment into the
  #   next, so indirection escapes it:
  #     f=<file> && cat "$f"
  #     [ -f <file> ] && cat "$_"
  #     cp <file> /tmp/x && cat /tmp/x
  #   Each carries the filename across a real command boundary in a variable,
  #   in $_, or in a copy -- which needs dataflow, not a keyword. The fourth
  #   member of this list, `for f in <file>; do cat $f; done`, was NOT one of
  #   them: nothing there crosses a boundary, only the `;` that introduces the
  #   `do` keyword stood between the filename and the verb. It is covered again
  #   (DO-598); see SEG_MERGE_KEYWORDS.
  #   The whole-string rule caught these by the same accident that made it
  #   refuse `git commit -m "... <file>"` -- filename anywhere plus verb
  #   anywhere. Keeping them would mean keeping that false positive; telling
  #   them apart needs real dataflow, which a command-string matcher does not
  #   have. Do not read the verb list as coverage.
  elif credential_file_read; then
    why="$CFR_WHY"
  # `printenv NAME` prints one variable's value. The bare-dump rule above
  # deliberately does not match it -- it requires `env`/`printenv` with no
  # operand -- so naming a credential variable walked past every rule here.
  elif [[ "$probe" =~ (^|[|;\&[:space:]])printenv[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)([[:space:]]|$) ]] \
       && secret_var_name "${BASH_REMATCH[2]}"; then
    why="\`printenv ${BASH_REMATCH[2]}\` prints a credential"
  elif secret_var_expansion; then
    why="$SVE_WHY"
  fi
fi

[[ -n "$why" ]] || allow

jq -n --arg why "$why" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ($why + ". Pipe it through the redactor: `<command> 2>&1 | ~/.dotfiles/scripts/redact-secrets.sh`. Everything printed here is recorded in the session transcript, which is why this is refused rather than warned about.")
  }
}'
