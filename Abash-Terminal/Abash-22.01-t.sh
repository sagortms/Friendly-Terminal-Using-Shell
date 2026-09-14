#!/usr/bin/env bash
#
# Abash22t — Advanced Bash Friendly Terminal (terminal-only edition)
# Author: Sagor Ahmed
#
# A natural-language shell wrapper you never have to leave: type plain
# English and get things done — create/move/delete files and folders,
# search by name or by content, open files by description, and drop into
# any raw bash command whenever you want. Run `help` inside it for the
# full command reference with examples.
#
# This edition runs as a single plain terminal session only — no tmux,
# no split-screen dashboard. Every natural-language command is identical
# to the full Abash22; only the GUI layer is left out.
#
abash_version="22.01-t"

# Requires your Mac login password before Abash starts (see
# require_login() below). Set to 0, or run
# ABASH_REQUIRE_LOGIN=0 bash Abash22.sh, to skip it.
ABASH_REQUIRE_LOGIN=${ABASH_REQUIRE_LOGIN:-1}

# ---------------------------------------------------------------------------
# 1. Look & feel
# ---------------------------------------------------------------------------

if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    C_RED=$(tput setaf 1);    C_GREEN=$(tput setaf 2);   C_YELLOW=$(tput setaf 3)
    C_BLUE=$(tput setaf 4);   C_MAGENTA=$(tput setaf 5); C_CYAN=$(tput setaf 6)
    C_BOLD=$(tput bold);      C_DIM=$(tput dim);         C_RESET=$(tput sgr0)
else
    C_RED="";C_GREEN="";C_YELLOW="";C_BLUE="";C_MAGENTA="";C_CYAN="";C_BOLD="";C_DIM="";C_RESET=""
fi

repeat_char() {
    local char="$1" count="$2" out=""
    local i=0
    while [ "$i" -lt "$count" ]; do out="${out}${char}"; i=$((i + 1)); done
    printf '%s' "$out"
}

print_banner() {
    local title="  ABASH ${abash_version}  —  Advanced Bash Friendly Terminal  "
    local border
    border=$(repeat_char "=" "${#title}")
    echo -e "${C_CYAN}${C_BOLD}+${border}+"
    echo -e "|${title}|"
    echo -e "+${border}+${C_RESET}"
}

print_success() { # msg [path]
    echo -e "${C_GREEN}${C_BOLD}[OK]${C_RESET} $1"
    [ -n "$2" ] && echo -e "     ${C_CYAN}Location:${C_RESET} $2"
}
print_error() { echo -e "${C_RED}${C_BOLD}[ERROR]${C_RESET} $1"; }
print_warn()  { echo -e "${C_YELLOW}${C_BOLD}[WARN]${C_RESET} $1"; }
print_info()  { echo -e "${C_BLUE}${C_BOLD}[INFO]${C_RESET} $1"; }
hr()          { echo -e "${C_DIM}$(repeat_char "-" 50)${C_RESET}"; }

shorten_path() {
    case "$PWD" in
        "$HOME") printf '~' ;;
        "$HOME"/*) printf '~%s' "${PWD#"$HOME"}" ;;
        *) printf '%s' "$PWD" ;;
    esac
}

# require_login -> optional password gate, run once before the REPL
# starts. Verifies via `su <yourself> -c true`: `su` always asks for the target
# account's password (confirmed: it does NOT silently pass through when
# the target is the same as the caller — tested by starving it of input,
# which makes it fail rather than succeed), so this checks your real
# login credential locally, via a core utility present on macOS and every
# Linux distro alike, without this script ever seeing, storing, logging,
# or transmitting the password itself — `su` reads and verifies it
# directly. Skipped (with a warning, not a lockout) if `su` is missing or
# there's no real terminal to prompt on, since a broken/unusable auth
# mechanism shouldn't be able to lock you out of your own machine's tool
# — but a wrong password still counts as wrong.
require_login() {
    [ "$ABASH_REQUIRE_LOGIN" = "1" ] || return 0
    if ! command -v su >/dev/null 2>&1; then
        print_warn "Can't verify a password on this system (no 'su' found) — skipping the login gate."
        return 0
    fi
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        print_warn "No interactive terminal to prompt for a password — skipping the login gate."
        return 0
    fi
    print_info "Abash is locked. Enter your password to continue (up to 3 tries)."
    local tries=0
    while [ "$tries" -lt 3 ]; do
        if su "$(whoami)" -c true; then
            print_success "Unlocked."
            return 0
        fi
        tries=$((tries + 1))
        print_error "Incorrect password. ($((3 - tries)) attempt(s) left)"
    done
    print_error "Too many failed attempts."
    return 1
}

# ---------------------------------------------------------------------------
# 2. Small portable helpers (no grep -P / no awk — plain Bash + POSIX tools)
# ---------------------------------------------------------------------------

# has_word HAYSTACK WORD -> true if WORD appears as a whole space-separated
# word in HAYSTACK. Prevents substring false-positives (e.g. "file" inside
# "profile", or "rm" inside "farm").
has_word() {
    local haystack=" $1 " needle=" $2 "
    case "$haystack" in
        *"$needle"*) return 0 ;;
        *) return 1 ;;
    esac
}

# has_prefix_word HAYSTACK PREFIX -> true if some whole word in HAYSTACK
# starts with PREFIX. Used only for intent DETECTION (e.g. "make"/"making"/
# "makes" should all trigger folder creation) — never for text mutation,
# so it can't reintroduce the substring-corruption bugs the old Abash16
# awk-based autocorrect had.
has_prefix_word() {
    local haystack="$1" prefix="$2" w
    for w in $haystack; do
        case "$w" in "$prefix"*) return 0 ;; esac
    done
    return 1
}

# Grouped synonym checks, so new vocabulary only needs to be added in one place.
is_show()   { has_prefix_word "$1" "show" || has_prefix_word "$1" "display" || has_prefix_word "$1" "list"; }
is_delete() { has_prefix_word "$1" "delet" || has_prefix_word "$1" "remov" || has_prefix_word "$1" "eras" || has_word "$1" "trash" || has_word "$1" "rm"; }
is_copy()   { has_prefix_word "$1" "copy" || has_prefix_word "$1" "duplicat" || has_word "$1" "cp"; }
is_move()   { has_prefix_word "$1" "mov" || has_prefix_word "$1" "renam" || has_word "$1" "mv"; }

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# lookup_alias KEY -> the saved expansion for KEY from $ALIAS_FILE (exact
# match, "key=value" per line), or empty if none. No associative arrays
# here on purpose — bash 3.2 (macOS's default /bin/bash) doesn't have them.
lookup_alias() {
    local key="$1" k v
    [ -f "$ALIAS_FILE" ] || return 0
    while IFS='=' read -r k v; do
        if [ "$k" = "$key" ]; then printf '%s' "$v"; return 0; fi
    done < "$ALIAS_FILE"
}

# remove_last_line FILE -> drops the final line of FILE in place. Used by
# the trash "undo" command. Deliberately avoids `sed -i` — BSD sed (macOS)
# and GNU sed (Linux) take that flag's argument differently, a classic
# portability footgun; head+mv works identically everywhere.
remove_last_line() {
    local f="$1" tmp total
    [ -s "$f" ] || return 0
    tmp=$(mktemp)
    total=$(wc -l < "$f" | tr -d ' ')
    if [ "$total" -gt 1 ]; then
        head -n $((total - 1)) "$f" > "$tmp" && mv "$tmp" "$f"
    else
        rm -f "$tmp"
        : > "$f"
    fi
}

# last_word_fallback INPUT -> the trailing word of INPUT, unless it's a
# filler/keyword with no real content. Lets simple one-word commands like
# "delete notes.txt" work without quotes. Callers pass $RAW_USER_INPUT
# (the untouched original line), not the autocorrected/lowercased $input —
# otherwise "delete Images" would look for "images", which silently
# "works" on macOS's case-insensitive filesystem but fails outright on
# Linux's case-sensitive one.
last_word_fallback() {
    local w="${1##* }" lw
    lw=$(printf '%s' "$w" | tr '[:upper:]' '[:lower:]')
    case "$lw" in
        file|files|folder|folders|directory|directories|it|this|that|location|locations|name|names|of|contents|""|to|at|in) printf '' ;;
        *) printf '%s' "$w" ;;
    esac
}

# resolve_path PATH -> absolute, normalised path (handles ~, relative paths)
resolve_path() {
    local p="$1"
    if [ -z "$p" ]; then printf '%s' "$PWD"; return; fi
    case "$p" in
        "~") p="$HOME" ;;
        "~/"*) p="$HOME/${p#\~/}" ;;
    esac
    case "$p" in
        /*) : ;;
        *) p="$PWD/$p" ;;
    esac
    if [ -d "$p" ]; then
        (cd "$p" 2>/dev/null && pwd) || printf '%s' "$p"
    else
        printf '%s' "$p"
    fi
}

# combine_path NAME LOCATION -> a usable path for a file/folder target,
# honouring an absolute NAME (ignores LOCATION) or falling back to $PWD.
combine_path() {
    local name="$1" loc="$2"
    case "$name" in
        /*|"~"*) resolve_path "$name" ;;
        *)
            [ -z "$loc" ] && loc="$PWD"
            loc=$(resolve_path "$loc")
            printf '%s/%s' "$loc" "$name"
            ;;
    esac
}

# get_quoted_array TEXT -> fills global array quoted_arr with every
# "..."-delimited substring found, in order.
#
# CRITICAL: the removal step below uses pure length/offset slicing
# (${rest:offset:length}), never ${var/pattern/replacement} or any other
# glob-pattern substitution against the captured content. A quoted value
# containing glob metacharacters (e.g. "Photo [1].jpg", "notes*.txt") would
# otherwise be re-interpreted as a wildcard pattern by the shell — on a
# no-match it silently loops forever, hanging the whole session on
# something as ordinary as a bracketed filename.
get_quoted_array() {
    quoted_arr=()
    local rest="$1"
    local prefix plen clen
    while [[ "$rest" =~ \"([^\"]*)\" ]]; do
        quoted_arr+=("${BASH_REMATCH[1]}")
        prefix="${rest%%\"*}"
        plen=${#prefix}
        clen=${#BASH_REMATCH[1]}
        rest="${prefix}${rest:$((plen + clen + 2))}"
    done
}

extract_name() {
    if [[ "$1" =~ (name|names|named|called|title)[[:space:]]\"([^\"]*)\" ]]; then
        printf '%s' "${BASH_REMATCH[2]}"
    fi
}

extract_location() {
    if [[ "$1" =~ (location|locations|in|at)[[:space:]]\"([^\"]*)\" ]]; then
        printf '%s' "${BASH_REMATCH[2]}"
    fi
}

# word2number WORD -> prints 1-20 for a recognised number word/digit,
# prints nothing (and the caller decides what to do) if unrecognised.
word2number() {
    case "$1" in
        a|an|one) echo 1 ;;
        two) echo 2 ;;
        three) echo 3 ;;
        four) echo 4 ;;
        five) echo 5 ;;
        six) echo 6 ;;
        seven) echo 7 ;;
        eight) echo 8 ;;
        nine) echo 9 ;;
        ten) echo 10 ;;
        eleven) echo 11 ;;
        twelve) echo 12 ;;
        thirteen) echo 13 ;;
        fourteen) echo 14 ;;
        fifteen) echo 15 ;;
        sixteen) echo 16 ;;
        seventeen) echo 17 ;;
        eighteen) echo 18 ;;
        nineteen) echo 19 ;;
        twenty) echo 20 ;;
        ''|*[!0-9]*) : ;;   # not a plain number either -> print nothing
        *) echo "$1" ;;     # plain digit string, e.g. "12"
    esac
}

# ordinal_to_number WORD -> 1-10 for "first".."tenth" (or "1st".."10th"),
# empty otherwise. Separate from word2number(), which only understands
# CARDINAL words (one/two/three) — pick_from_results/offer_suggestions
# need ordinals ("first"/"second") to pick an item from a numbered list.
ordinal_to_number() {
    case "$1" in
        first|1st) echo 1 ;;
        second|2nd) echo 2 ;;
        third|3rd) echo 3 ;;
        fourth|4th) echo 4 ;;
        fifth|5th) echo 5 ;;
        sixth|6th) echo 6 ;;
        seventh|7th) echo 7 ;;
        eighth|8th) echo 8 ;;
        ninth|9th) echo 9 ;;
        tenth|10th) echo 10 ;;
        *) : ;;
    esac
}

# ---------------------------------------------------------------------------
# 3. Autocorrect — exact whole-word matching only.
#    Quoted sections (names/paths) are protected before this ever touches
#    the string, and restored with their original text and case afterwards.
# ---------------------------------------------------------------------------

correct_word() {
    case "$1" in
        eixt|exti|xite) echo "exit" ;;
        quite|qiut|qut) echo "quit" ;;
        colse|cloes|clse) echo "close" ;;
        terninate|tarminate|tarninate|terminet|termnate) echo "terminate" ;;
        mak|mkae|mek|makes|makse) echo "make" ;;
        derectory|directroy|direcotry|dirctory|dircetory|diretory) echo "directory" ;;
        derectories|dirctories|directries|direcotries) echo "directories" ;;
        foldar|foler|fodler) echo "folder" ;;
        foldars|folers|fodlers) echo "folders" ;;
        craete|crete|crtae|creat|creates) echo "create" ;;
        nmae|naem) echo "name" ;;
        nmaes|nams|naems) echo "names" ;;
        locaton|loaction|loctaion|locaiton) echo "location" ;;
        locationss|loactons|loctaions) echo "locations" ;;
        wher|whre) echo "where" ;;
        curent) echo "current" ;;
        shw) echo "show" ;;
        ful) echo "full" ;;
        hiden) echo "hidden" ;;
        *) echo "$1" ;;
    esac
}

autocorrect_user_input() {
    local raw="$1"
    local -a quoted=()
    local work="$raw"
    local i=0

    # Step 1: pull every "..." section out into a placeholder, so nothing
    # below can ever touch the text a user put in quotes.
    #
    # CRITICAL: built with pure length/offset slicing, never
    # ${var/pattern/replacement} against the captured content — that form
    # re-interprets the content as a glob pattern, so a quoted value with
    # brackets/wildcards ("Photo [1].jpg") makes the pattern never match
    # and this loop spins forever, hanging on the most ordinary filename.
    local prefix plen clen suffix
    while [[ "$work" =~ \"([^\"]*)\" ]]; do
        quoted+=("${BASH_REMATCH[1]}")
        prefix="${work%%\"*}"
        plen=${#prefix}
        clen=${#BASH_REMATCH[1]}
        suffix="${work:$((plen + clen + 2))}"
        work="${prefix}"$'\x01'"$i"$'\x01'"${suffix}"
        i=$((i + 1))
    done

    # Step 2: lowercase + typo-correct each remaining word, whole-word only.
    local corrected="" w lw fixed
    for w in $work; do
        case "$w" in
            *$'\x01'*$'\x01'*) corrected="${corrected}${w} " ;;
            *)
                lw=$(printf '%s' "$w" | tr '[:upper:]' '[:lower:]')
                fixed=$(correct_word "$lw")
                corrected="${corrected}${fixed} "
                ;;
        esac
    done
    corrected=$(trim "$corrected")

    # Step 3: put the original, untouched quoted text back.
    local idx
    for idx in "${!quoted[@]}"; do
        corrected="${corrected/$'\x01'$idx$'\x01'/\"${quoted[$idx]}\"}"
    done

    printf '%s' "$corrected"
}

# ---------------------------------------------------------------------------
# 4. Directory creation (multi-folder flow, with interactive fallbacks)
# ---------------------------------------------------------------------------

create_directories() {
    local names_csv="$1" count="$2" location="$3"

    if [ ! -d "$location" ]; then
        print_info "Location '$location' doesn't exist yet — creating it."
        mkdir -p "$location"
    fi

    local -a names=()
    if [ -n "$names_csv" ]; then
        local OLDIFS="$IFS"
        IFS=','
        read -r -a names <<< "$names_csv"
        IFS="$OLDIFS"
        local j
        for j in "${!names[@]}"; do
            names[$j]=$(trim "${names[$j]}")
        done
    fi

    local base="New Folder"
    [ "${#names[@]}" -gt 0 ] && base="${names[0]}"

    local created=0 idx=0 title
    while [ "$created" -lt "$count" ]; do
        if [ "$idx" -lt "${#names[@]}" ]; then
            title="${names[$idx]}"
        elif [ "${#names[@]}" -gt 0 ]; then
            title="${base} $((idx + 1))"
        elif [ "$count" -eq 1 ]; then
            title="New Folder"
        else
            title="New Folder $((idx + 1))"
        fi

        if [ ! -d "$location/$title" ]; then
            mkdir -p "$location/$title"
            print_success "Directory '$title' created." "$location"
        else
            print_warn "Directory '$title' already exists at '$location'."
        fi
        idx=$((idx + 1))
        created=$((created + 1))
    done
}

# ---------------------------------------------------------------------------
# 5. Smart file search & open — Spotlight on macOS, locate/find on Linux
# ---------------------------------------------------------------------------

# open_file PATH -> opens PATH in its default app, whatever the OS.
open_file() {
    local f="$1"
    if [ "$(uname)" = "Darwin" ]; then
        open "$f"
    elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$f" >/dev/null 2>&1 &
    else
        print_warn "No file opener found on this system (install xdg-utils) — the path is above."
    fi
}

# pkg_install_hint -> the right install command for whichever package
# manager this system actually has (Homebrew, apt, dnf, yum, pacman,
# zypper, apk), so tips don't assume every user is on a Mac.
pkg_install_hint() {
    local pkg="$1"
    if command -v brew >/dev/null 2>&1; then echo "brew install $pkg"
    elif command -v apt >/dev/null 2>&1; then echo "sudo apt install $pkg"
    elif command -v dnf >/dev/null 2>&1; then echo "sudo dnf install $pkg"
    elif command -v yum >/dev/null 2>&1; then echo "sudo yum install $pkg"
    elif command -v pacman >/dev/null 2>&1; then echo "sudo pacman -S $pkg"
    elif command -v zypper >/dev/null 2>&1; then echo "sudo zypper install $pkg"
    elif command -v apk >/dev/null 2>&1; then echo "sudo apk add $pkg"
    else echo "your package manager's '$pkg' package"
    fi
}

# filter_valid_paths TEXT -> TEXT, one path per line, keeping only lines
# that are actual existing filesystem entries.
#
# IMPORTANT: on at least some macOS systems, `mdfind` prints diagnostic
# lines like "[UserQueryParser] Loading keywords..." to STDOUT (not
# stderr), so `2>/dev/null` does nothing about it. That junk makes
# $results non-empty even on a genuine zero-match search, which would
# fool any "did we actually find anything?" check downstream (both here
# and in smart_open) into skipping its fallback/suggestion logic.
# Filtering to real paths keeps that check honest regardless of how much
# log spam mdfind prints on a given system.
filter_valid_paths() {
    local f
    while IFS= read -r f; do
        [ -e "$f" ] && printf '%s\n' "$f"
    done <<< "$1"
}

# find_dir_by_name NAME -> newline-separated list of directories under
# $HOME whose name matches NAME (Spotlight on macOS, `find` elsewhere).
# Lets "go to Videos" work even when Videos isn't in the current
# directory. Deliberately scoped to $HOME, not searched system-wide:
# common folder names like "Videos"/"Documents" collide with huge numbers
# of unrelated macOS framework/bundle names and would bury the directory
# the user actually meant.
find_dir_by_name() {
    local name="$1" md_results="" find_results=""
    if [ "$(uname)" = "Darwin" ] && command -v mdfind >/dev/null 2>&1; then
        # Exact (case-insensitive) name match — plain `mdfind -name` does
        # fuzzy substring matching, which for a common word like "Videos"
        # returns a flood of unrelated framework/bundle paths and buries
        # the one real folder the user meant. kMDItemFSName ==[c] is
        # precise instead.
        md_results=$(mdfind -onlyin "$HOME" "kMDItemFSName ==[c] '$name'" </dev/null 2>/dev/null)
        md_results=$(filter_valid_paths "$md_results")
    fi
    # Only fall back to `find` when mdfind found nothing: walking a real,
    # populated $HOME (~/Library especially, full of permission-denied
    # paths) is slow, so it's not worth paying for when mdfind already
    # answered. `find` is still needed to catch a folder created moments
    # ago, since Spotlight has real indexing lag. ~/Library is skipped
    # since personal folders are never in there, but heavy app-support
    # data that slows the scan down often is.
    # (</dev/null: a subprocess that inherits this script's own piped
    # stdin can end up consuming bytes meant for the next `read`.)
    if [ -z "$md_results" ]; then
        find_results=$(find "$HOME" -maxdepth 4 -iname "$name" \
            -not -path "$HOME/Library/*" -not -path "$HOME/.Trash/*" -not -path "*/node_modules/*" \
            </dev/null 2>/dev/null)
    fi
    local f
    { printf '%s\n' "$md_results"; printf '%s\n' "$find_results"; } | while IFS= read -r f; do
        [ -n "$f" ] && [ -d "$f" ] && printf '%s\n' "$f"
    done | sort -u | head -20
}

# pick_from_results RESULTS DEFAULT_BEST [PROMPT_VERB] -> if RESULTS has
# more than one line, shows a numbered list and lets the user choose
# (Enter keeps DEFAULT_BEST); otherwise just returns DEFAULT_BEST. The
# answer can be a number, a number word ("first", "second", ...), or a
# full path pasted directly (used verbatim, bypassing RESULTS entirely).
# Used both for smart_open's multi-match picker and cd's "which folder?".
pick_from_results() {
    # IMPORTANT: every call site captures this function's return value
    # with $(...), e.g. `chosen=$(pick_from_results ...)`. Command
    # substitution captures stdout, so anything printed with print_info/
    # printf (which default to stdout) would be silently swallowed into
    # the variable instead of ever reaching the screen. Every line meant
    # to be SEEN must go to stderr (>&2); only the final chosen path is
    # allowed to stay on stdout.
    local results="$1" default_best="$2" verb="${3:-open}"
    local count; count=$(printf '%s\n' "$results" | wc -l | tr -d ' ')
    if [ "$count" -gt 1 ]; then
        print_info "Multiple matches found:" >&2
        local i=1 f
        while IFS= read -r f; do
            printf '  %d) %s\n' "$i" "$f" >&2
            i=$((i + 1))
        done <<< "$results"
        local choice picked idx
        # Prompt printed explicitly to stderr, then a plain `read` (no
        # -p): letting `read -p` print its own prompt leaves it unclear
        # which stream it lands on once this function's stdout is being
        # captured — being explicit here removes that ambiguity entirely.
        printf '%s' "$(echo -e "${C_CYAN}Which one would you like to $verb? (number, \"first\"/\"second\"/..., a full path, or Enter for the suggested default): ${C_RESET}")" >&2
        read -e choice
        if [ -n "$choice" ]; then
            case "$choice" in
                /*|"~"*) printf '%s' "$choice"; return ;;
            esac
            idx="$choice"
            case "$idx" in *[!0-9]*) idx=$(ordinal_to_number "$(printf '%s' "$idx" | tr '[:upper:]' '[:lower:]')") ;; esac
            if [ -n "$idx" ]; then
                picked=$(printf '%s\n' "$results" | sed -n "${idx}p")
                [ -n "$picked" ] && { printf '%s' "$picked"; return; }
            fi
        fi
    fi
    printf '%s' "$default_best"
}

# offer_suggestions LIST -> when a search finds nothing, show whatever
# LIST of "maybe you meant one of these" candidates the caller found
# (same file kind, or same first word) and let the user open one by
# number/word, or skip.
offer_suggestions() {
    # Same reasoning as pick_from_results: display lines go to stderr on
    # purpose, in case a future caller wraps this in $(...).
    local suggestions="$1"
    [ -z "$suggestions" ] && return 1
    print_info "Here are similar files — maybe one of these?" >&2
    local i=1 f
    while IFS= read -r f; do
        printf '  %d) %s\n' "$i" "$f" >&2
        i=$((i + 1))
    done <<< "$suggestions"
    local choice idx picked
    printf '%s' "$(echo -e "${C_CYAN}Open one of these? (number, \"first\"/\"second\"/..., or Enter to skip): ${C_RESET}")" >&2
    read -e choice
    [ -z "$choice" ] && return 1
    idx=$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')
    case "$idx" in *[!0-9]*) idx=$(ordinal_to_number "$idx") ;; esac
    [ -z "$idx" ] && return 1
    picked=$(printf '%s\n' "$suggestions" | sed -n "${idx}p")
    if [ -n "$picked" ] && [ -e "$picked" ]; then
        print_success "Opening '$picked'..." "$picked"
        open_file "$picked"
        return 0
    fi
    return 1
}

ABASH_STOPWORDS=" open launch play show me find the a an my please of that this named name called file document "

strip_stopwords() {
    local w out=""
    for w in $1; do
        case "$ABASH_STOPWORDS" in
            *" $w "*) : ;;
            *) out="$out $w" ;;
        esac
    done
    trim "$out"
}

kind_map() {
    case "$1" in
        pdf) echo "pdf" ;;
        video|movie|movies|film) echo "movie" ;;
        image|picture|photo|photos|pic) echo "image" ;;
        song|music|audio|mp3) echo "audio" ;;
        doc|document|word) echo "document" ;;
        excel|spreadsheet) echo "spreadsheet" ;;
        presentation|slides|powerpoint|ppt) echo "presentation" ;;
        text|txt) echo "text" ;;
        *) : ;;
    esac
}

# smart_open QUERY -> finds the best-matching file system-wide and opens it
# in its default app. QUERY is free text, e.g. "my number pdf".
smart_open() {
    local query="$1"
    local kind="" rest="" w k
    for w in $query; do
        k=$(kind_map "$w")
        if [ -n "$k" ] && [ -z "$kind" ]; then
            kind="$k"
        else
            rest="$rest $w"
        fi
    done
    rest=$(trim "$rest")

    if [ "$(uname)" = "Darwin" ] && command -v mdfind >/dev/null 2>&1; then
        local spotlight_query
        if [ -n "$kind" ] && [ -n "$rest" ]; then
            spotlight_query="kind:$kind $rest"
        elif [ -n "$kind" ]; then
            spotlight_query="kind:$kind"
        else
            spotlight_query="$rest"
        fi
        if [ -z "$spotlight_query" ]; then
            print_error "Please tell me a bit more about what to open."
            return 1
        fi
        print_info "Searching your Mac for: $spotlight_query"
        local results
        results=$(filter_valid_paths "$(mdfind "$spotlight_query" </dev/null 2>/dev/null)" | head -50)
        if [ -z "$results" ]; then
            print_warn "Couldn't find anything matching '$query'."
            # No exact match — suggest same-kind (or same-first-word)
            # files instead of just giving up.
            local suggest_query=""
            if [ -n "$kind" ]; then
                suggest_query="kind:$kind"
            elif [ -n "$rest" ]; then
                set -- $rest
                suggest_query="$1"
            fi
            if [ -n "$suggest_query" ]; then
                offer_suggestions "$(filter_valid_paths "$(mdfind -onlyin "$HOME" "$suggest_query" </dev/null 2>/dev/null)" | head -20)"
            fi
            return 1
        fi
        local best="" f newest=0 mtime
        while IFS= read -r f; do
            [ -e "$f" ] || continue
            mtime=$(stat -f '%m' "$f" 2>/dev/null || echo 0)
            if [ "$mtime" -gt "$newest" ]; then
                newest=$mtime; best="$f"
            fi
        done <<< "$results"
        [ -z "$best" ] && best=$(printf '%s\n' "$results" | head -1)
        best=$(pick_from_results "$results" "$best")
        print_success "Found '$best' — opening it now." "$best"
        open_file "$best"
    else
        # Linux/other: try locate/plocate first (instant, indexed search,
        # exactly like mdfind), then fall back to a manual `find`.
        local search_term="${rest:-$query}"
        print_info "Searching for files matching '$search_term'..."
        local results=""
        if command -v plocate >/dev/null 2>&1; then
            results=$(plocate -i "$search_term" </dev/null 2>/dev/null | head -50)
        elif command -v locate >/dev/null 2>&1; then
            results=$(locate -i "$search_term" </dev/null 2>/dev/null | head -50)
        fi
        if [ -z "$results" ]; then
            results=$(find "$HOME" -iname "*$search_term*" </dev/null 2>/dev/null | head -50)
        fi
        if [ -z "$results" ]; then
            print_warn "Couldn't find anything matching '$search_term'."
            # Broaden to just the first word and suggest those.
            local first_word; set -- $search_term; first_word="$1"
            if [ -n "$first_word" ] && [ "$first_word" != "$search_term" ]; then
                local suggestions=""
                if command -v plocate >/dev/null 2>&1; then
                    suggestions=$(plocate -i "$first_word" </dev/null 2>/dev/null | head -20)
                elif command -v locate >/dev/null 2>&1; then
                    suggestions=$(locate -i "$first_word" </dev/null 2>/dev/null | head -20)
                else
                    suggestions=$(find "$HOME" -iname "*$first_word*" </dev/null 2>/dev/null | head -20)
                fi
                offer_suggestions "$suggestions"
            fi
            return 1
        fi
        local best
        best=$(printf '%s\n' "$results" | head -1)
        best=$(pick_from_results "$results" "$best")
        print_success "Found '$best' — opening it now." "$best"
        open_file "$best"
    fi
}

# ---------------------------------------------------------------------------
# 6. Raw shell passthrough — never have to leave Abash for real work
# ---------------------------------------------------------------------------

# try_raw_command RAW_INPUT -> runs RAW_INPUT as a genuine shell command if
# its first word is a real command (or it's prefixed with "!" to force it).
# Returns 1 (untried) if it clearly isn't a shell command, so the caller can
# fall back to a normal "I don't understand" message.
try_raw_command() {
    local raw="$1" forced=0
    case "$raw" in
        "!"*) raw="${raw#!}"; raw=$(trim "$raw"); forced=1 ;;
    esac
    [ -z "$raw" ] && return 1

    local first_word
    set -- $raw
    first_word="$1"

    if [ "$forced" -eq 1 ] || command -v "$first_word" >/dev/null 2>&1 || [ -x "$first_word" ]; then
        # A raw command still runs through eval — that's the point (it's a
        # real shell). The one guard we add is a confirmation for patterns
        # that are almost never typed by accident-tolerant intent (wiping a
        # whole disk, blanket chmod 777, etc.), so a stray or pasted command
        # doesn't execute instantly with zero chance to back out.
        case "$raw" in
            *"rm -rf /"*|*"rm -rf ~"*|*"rm -rf *"*|*mkfs*|*" dd "*|"dd "*|*"chmod -R 777"*|*"chmod 777 -R"*)
                local confirm
                read -e -p "$(echo -e "${C_YELLOW}This looks destructive: '$raw'. Run it anyway? (y/N): ${C_RESET}")" confirm
                case "$confirm" in
                    y|Y|yes|Yes|YES) : ;;
                    *) print_info "Cancelled."; return 0 ;;
                esac
                ;;
        esac
        print_info "Running as a shell command: $raw"
        hr
        eval "$raw"
        local rc=$?
        hr
        if [ "$rc" -eq 0 ]; then
            print_success "Command completed." "$PWD"
        else
            print_warn "Command exited with status $rc."
        fi
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# 7. Help
# ---------------------------------------------------------------------------

print_help() {
    hr
    printf "%s\n" "${C_BOLD}${C_MAGENTA}Abash${abash_version} — Command Reference${C_RESET}"
    hr
    printf "%s\n" "${C_YELLOW}Folders${C_RESET}"
    printf "  %-58s %s\n" 'create a folder named "X" location "/path"' "-> mkdir -p"
    printf "  %-58s %s\n" 'create folders named "A, B, C" location "/path"' "-> multiple mkdir"
    printf "  %-58s %s\n" 'create five folders' "(asks for name/location if needed)"
    printf "  %-58s %s\n" 'mkdir <name>' "(raw, current directory)"
    printf "%s\n" "${C_YELLOW}Files${C_RESET}"
    printf "  %-58s %s\n" 'create file "notes.txt" location "/path"' "-> touch"
    printf "  %-58s %s\n" 'show contents of "notes.txt"  /  cat notes.txt' "-> cat"
    printf "  %-58s %s\n" 'copy/duplicate "file.txt" to "/path"' "-> cp"
    printf "  %-58s %s\n" 'move "file.txt" to "/path"  /  rename "a" to "b"' "-> mv"
    printf "  %-58s %s\n" 'delete/remove/erase/trash "file.txt"' "-> moved to trash"
    printf "  %-58s %s\n" 'delete "file.txt" permanently' "-> rm, no trash"
    printf "  %-58s %s\n" 'undo' "restore the last trashed item"
    printf "  %-58s %s\n" 'write "text" to "notes.txt"' "overwrite a file's contents"
    printf "  %-58s %s\n" 'append "text" to "notes.txt"' "add to a file's contents"
    printf "  %-58s %s\n" 'find the word "Error" in "app.log"' "-> grep, search inside files"
    printf "  %-58s %s\n" 'compress/zip "MyFolder"' "-> .zip (also: as \"x.tar.bz2\"/\"x.7z\")"
    printf "  %-58s %s\n" 'extract/unzip "archive.zip"' ".zip/.tar(.gz)/.tar.bz2/.7z"
    printf "  %-58s %s\n" 'make "script.sh" executable' "-> chmod +x"
    printf "  %-58s %s\n" 'what kind of file is "notes.txt"' "-> file"
    printf "  %-58s %s\n" 'how many lines in "notes.txt"' "-> wc -l"
    printf "  %-58s %s\n" 'combine "a.txt" and "b.txt" into "c.txt"' "-> cat a b > c"
    printf "%s\n" "${C_YELLOW}Trash & Clipboard${C_RESET}"
    printf "  %-58s %s\n" 'show trash  /  what'"'"'s in the trash' "-> ls ~/.abash_trash"
    printf "  %-58s %s\n" 'empty trash' "permanently deletes everything trashed"
    printf "  %-58s %s\n" 'empty folder "Downloads"' "clears contents, keeps the folder"
    printf "  %-58s %s\n" 'copy "some text" to clipboard' "-> pbcopy / xclip"
    printf "  %-58s %s\n" 'paste clipboard  /  show clipboard' "-> pbpaste / xclip -o"
    printf "%s\n" "${C_YELLOW}Open Anything${C_RESET}"
    printf "  %-58s %s\n" 'open "report.pdf"' "opens a known file"
    printf "  %-58s %s\n" 'open my number pdf  /  play that vacation video' "Spotlight-searches your whole system"
    printf "  %-58s %s\n" '(if more than one match, you'"'"'ll be asked which)' ""
    printf "  %-58s %s\n" "(no match at all? you'll get similar suggestions)" ""
    printf "%s\n" "${C_YELLOW}Navigation${C_RESET}"
    printf "  %-58s %s\n" 'go to "/path"  /  open folder "Projects"  /  cd <path>' "-> cd"
    printf "  %-58s %s\n" 'go to Videos' "not here? searches your home folder for it"
    printf "  %-58s %s\n" '(multiple matches -> pick by number, "first"/' ""
    printf "  %-58s %s\n" ' "second"/..., or paste a full path)' ""
    printf "  %-58s %s\n" 'back' "-> cd .. (one level up)"
    printf "  %-58s %s\n" 'back to "/path"' "same as go to — another way to say it"
    printf "  %-58s %s\n" 'where am i  /  pwd  /  current directory' "-> pwd"
    printf "  %-58s %s\n" 'alias "dl" as "cd ~/Downloads"' "save your own shortcut"
    printf "  %-58s %s\n" 'show my aliases  /  list aliases' ""
    printf "  %-58s %s\n" 'remove alias "dl"  /  delete alias "dl"' ""
    printf "%s\n" "${C_YELLOW}Listing${C_RESET}"
    printf "  %-58s %s\n" 'show list  /  show full list' "-> ls  /  ls -l"
    printf "  %-58s %s\n" 'show hidden list  /  show all list' "-> ls -a  /  ls -la"
    printf "  %-58s %s\n" 'show structure of "/path"' "tree view"
    printf "  %-58s %s\n" 'count files  /  how many files' "-> item count"
    printf "%s\n" "${C_YELLOW}System & Network${C_RESET}"
    printf "  %-58s %s\n" 'search for "name" location "/path"' "-> find, by filename"
    printf "  %-58s %s\n" 'show size of "/path"' "-> du -sh"
    printf "  %-58s %s\n" 'show free space  /  show disk space' "-> df -h"
    printf "  %-58s %s\n" 'show processes  /  what is running' "-> ps aux"
    printf "  %-58s %s\n" 'show battery  /  battery status' ""
    printf "  %-58s %s\n" 'is this a git repo  /  am i in a git repository' ""
    printf "  %-58s %s\n" 'what is my ip' "-> public IP address"
    printf "  %-58s %s\n" 'ping "google.com"' ""
    printf "  %-58s %s\n" 'download "https://.../file.pdf" to "/path"' "-> curl"
    printf "  %-58s %s\n" 'history  /  clear history  /  clear  /  whoami  /  date' ""
    printf "%s\n" "${C_YELLOW}Just for Fun${C_RESET}"
    printf "  %-58s %s\n" 'take a screenshot' ""
    printf "  %-58s %s\n" "what's the weather  /  weather in \"Dhaka\"" ""
    printf "  %-58s %s\n" 'calculate 5 + 3  /  what is 12 * 4' ""
    printf "  %-58s %s\n" 'generate a random password' "(also: a 24 character password)"
    printf "  %-58s %s\n" 'remind me in 5 minutes to "take a break"' "desktop notification"
    printf "%s\n" "${C_YELLOW}Raw Shell${C_RESET}"
    printf "  %-58s %s\n" '!<command>  (e.g. !git status)' "always runs as a real shell command"
    printf "  %-58s %s\n" '<any unrecognised command>' "tried as a real shell command automatically"
    printf "%s\n" "${C_YELLOW}Session${C_RESET}"
    printf "  %-58s %s\n" 'help / commands' ""
    printf "  %-58s %s\n" 'exit / quit / close / terminate' ""
    hr
}

# ---------------------------------------------------------------------------
# 8. Main dispatcher
# ---------------------------------------------------------------------------

abash() {
    local input="$1"

    # --- help --------------------------------------------------------
    if has_word "$input" "help" || has_word "$input" "commands"; then
        print_help

    # --- clear/forget history — must stay ahead of "clear screen" below,
    # since it also contains the word "clear". -------------------------
    elif has_word "$input" "history" && { has_prefix_word "$input" "clear" || has_word "$input" "forget"; }; then
        : > "$HISTFILE" 2>/dev/null
        history -c
        print_success "Command history cleared."

    # --- clear screen --------------------------------------------------
    elif has_word "$input" "clear" || has_word "$input" "cls"; then
        clear

    # --- history ---------------------------------------------------------
    elif has_word "$input" "history"; then
        history

    # --- define an alias -----------------------------------------------------
    elif has_word "$input" "alias" && has_word "$input" "as"; then
        get_quoted_array "$input"
        local aliasname="${quoted_arr[0]}" aliasvalue="${quoted_arr[1]}"
        if [ -z "$aliasname" ] || [ -z "$aliasvalue" ]; then
            print_error 'Usage: alias "shortcut" as "the full command"'
        else
            printf '%s=%s\n' "$aliasname" "$aliasvalue" >> "$ALIAS_FILE"
            print_success "Alias '$aliasname' saved — type it any time to run: $aliasvalue" "$ALIAS_FILE"
        fi

    # --- list / remove aliases -- must stay ahead of the generic delete
    # branch below, since "remove alias X" also contains "remove". ----------
    elif has_prefix_word "$input" "alias" && { is_show "$input" || has_word "$input" "my"; }; then
        if [ -s "$ALIAS_FILE" ]; then
            print_info "Your aliases:"
            local k v
            while IFS='=' read -r k v; do
                printf '  %s  ->  %s\n' "$k" "$v"
            done < "$ALIAS_FILE"
        else
            print_info "You don't have any aliases yet. Try: alias \"dl\" as \"go to \\\"~/Downloads\\\"\""
        fi
    elif is_delete "$input" && has_prefix_word "$input" "alias"; then
        get_quoted_array "$input"
        local aliasname="${quoted_arr[0]}" existing_alias
        [ -z "$aliasname" ] && aliasname=$(last_word_fallback "$RAW_USER_INPUT")
        existing_alias=$(lookup_alias "$aliasname")
        if [ -z "$aliasname" ] || [ -z "$existing_alias" ]; then
            print_error "No alias named '$aliasname' found."
        else
            local tmp_alias; tmp_alias=$(mktemp)
            grep -v "^${aliasname}=" "$ALIAS_FILE" > "$tmp_alias" 2>/dev/null
            mv "$tmp_alias" "$ALIAS_FILE"
            print_success "Alias '$aliasname' removed."
        fi

    # --- trash management: show / empty — must stay ahead of the generic
    # delete branch below, since "trash" is also a delete synonym there.
    elif has_word "$input" "trash" && { is_show "$input" || has_word "$input" "what"; }; then
        mkdir -p "$TRASH_DIR" 2>/dev/null
        if [ -n "$(ls -A "$TRASH_DIR" 2>/dev/null | grep -v '^\.manifest$')" ]; then
            print_info "In the trash:"
            ls -1 "$TRASH_DIR" | grep -v '^\.manifest$'
        else
            print_info "The trash is empty."
        fi
    elif has_word "$input" "trash" && has_prefix_word "$input" "empt"; then
        mkdir -p "$TRASH_DIR" 2>/dev/null
        local confirm
        read -e -p "$(echo -e "${C_RED}Permanently empty the trash? This cannot be undone. (y/N): ${C_RESET}")" confirm
        case "$confirm" in
            y|Y|yes|Yes|YES)
                find "$TRASH_DIR" -mindepth 1 ! -name '.manifest' -exec rm -rf {} + 2>/dev/null
                : > "$TRASH_MANIFEST"
                print_success "Trash emptied." "$TRASH_DIR"
                ;;
            *) print_info "Cancelled." ;;
        esac

    # --- empty a folder's contents, keeping the folder itself --------------
    elif has_prefix_word "$input" "empt" && { has_word "$input" "folder" || has_word "$input" "directory"; }; then
        get_quoted_array "$input"
        local target="${quoted_arr[0]}"
        [ -z "$target" ] && target=$(last_word_fallback "$RAW_USER_INPUT")
        if [ -z "$target" ]; then
            print_error 'Please specify a folder, e.g. empty folder "Downloads".'
        else
            local full; full=$(combine_path "$target" "")
            if [ ! -d "$full" ]; then
                print_error "'$full' is not a directory."
            else
                local confirm
                read -e -p "$(echo -e "${C_YELLOW}Delete everything inside '$full' (keeping the folder itself)? (y/N): ${C_RESET}")" confirm
                case "$confirm" in
                    y|Y|yes|Yes|YES)
                        find "$full" -mindepth 1 -exec rm -rf {} + 2>/dev/null
                        print_success "Folder emptied." "$full"
                        ;;
                    *) print_info "Cancelled." ;;
                esac
            fi
        fi

    # --- clipboard — checked ahead of copy/move below, since "copy X to
    # clipboard" also contains "copy"/"to". ----------------------------------
    elif has_word "$input" "clipboard"; then
        if has_prefix_word "$input" "paste" || is_show "$input" || has_word "$input" "what"; then
            if [ "$(uname)" = "Darwin" ]; then
                pbpaste
            elif command -v xclip >/dev/null 2>&1; then
                xclip -o -selection clipboard 2>/dev/null
            elif command -v xsel >/dev/null 2>&1; then
                xsel --clipboard 2>/dev/null
            else
                print_error "No clipboard tool found (install xclip or xsel)."
            fi
        else
            get_quoted_array "$input"
            local content="${quoted_arr[0]}" text
            text="$content"
            local maybe_file; maybe_file=$(combine_path "$content" "")
            [ -f "$maybe_file" ] && text=$(cat "$maybe_file")
            if [ -z "$text" ]; then
                print_error 'Usage: copy "some text" to clipboard  (or a filename to copy its contents)'
            elif [ "$(uname)" = "Darwin" ]; then
                printf '%s' "$text" | pbcopy
                print_success "Copied to clipboard."
            elif command -v xclip >/dev/null 2>&1; then
                printf '%s' "$text" | xclip -selection clipboard
                print_success "Copied to clipboard."
            elif command -v xsel >/dev/null 2>&1; then
                printf '%s' "$text" | xsel --clipboard
                print_success "Copied to clipboard."
            else
                print_error "No clipboard tool found (install xclip or xsel)."
            fi
        fi

    # --- pwd / where am i --------------------------------------------------
    # Tightened to the literal phrase "where am i": has_word "where" &&
    # has_word "i" alone fires on any ordinary sentence containing the
    # standalone pronoun, e.g. "where should I look for my report".
    elif [[ " $input " == *" where am i "* ]] || \
         { has_word "$input" "current" && { has_word "$input" "directory" || has_word "$input" "folder"; }; } || \
         has_word "$input" "pwd"; then
        print_success "You are here." "$PWD"

    # --- plain "back" / "go back" / "back up" -> cd .. (one level up) ------
    # Distinct from "back to X" (a synonym for "go to X"), handled below.
    elif has_word "$input" "back" && ! has_word "$input" "to"; then
        cd .. || true
        print_success "Moved up to the parent directory." "$PWD"

    # --- cd / go to / back to / open folder / navigate / jump to -----------
    elif has_word "$input" "cd" || \
         { has_word "$input" "go" && has_word "$input" "to"; } || \
         { has_word "$input" "back" && has_word "$input" "to"; } || \
         { has_word "$input" "jump" && has_word "$input" "to"; } || \
         { has_prefix_word "$input" "open" && has_prefix_word "$input" "folder"; } || \
         has_prefix_word "$input" "navigat" || \
         { has_prefix_word "$input" "chang" && has_prefix_word "$input" "director"; }; then
        get_quoted_array "$input"
        local target="${quoted_arr[0]}"
        # last_word_fallback lets "go to Documents" (unquoted, no literal
        # "cd ") find a target the same way the other single-target
        # commands do, instead of falling back to $HOME.
        [ -z "$target" ] && target=$(last_word_fallback "$RAW_USER_INPUT")
        [ -z "$target" ] && target="$HOME"
        local dest
        dest=$(resolve_path "$target")
        if [ -d "$dest" ]; then
            cd "$dest" || true
            print_success "Changed directory." "$PWD"
        else
            # Not here — search nearby instead of just giving up.
            local matches
            matches=$(find_dir_by_name "$target")
            if [ -n "$matches" ]; then
                local chosen
                chosen=$(pick_from_results "$matches" "$(printf '%s\n' "$matches" | head -1)" "go to")
                chosen=$(resolve_path "$chosen")
                if [ -d "$chosen" ]; then
                    cd "$chosen" || true
                    print_success "Changed directory (found via search)." "$PWD"
                else
                    print_error "Directory '$dest' does not exist."
                fi
            else
                print_error "Directory '$dest' does not exist."
            fi
        fi

    # --- open/launch/play a FILE (not a folder) — Spotlight-powered --------
    elif has_prefix_word "$input" "open" || has_prefix_word "$input" "launch" || has_prefix_word "$input" "play"; then
        get_quoted_array "$input"
        local q="${quoted_arr[0]}"
        [ -z "$q" ] && q=$(strip_stopwords "$input")
        if [ -z "$q" ]; then
            print_error 'What should I open? e.g. open "notes.pdf" or open my number pdf'
        else
            local direct; direct=$(combine_path "$q" "")
            if [ -e "$direct" ]; then
                print_success "Opening '$direct'..." "$direct"
                open_file "$direct"
            else
                smart_open "$q"
            fi
        fi

    # --- delete / remove / erase / trash (moves to trash; see "undo") ------
    elif is_delete "$input"; then
        get_quoted_array "$input"
        local target="${quoted_arr[0]}"
        [ -z "$target" ] && target=$(last_word_fallback "$RAW_USER_INPUT")
        local loc; loc=$(extract_location "$input")
        if [ -z "$target" ]; then
            print_error 'Please specify what to delete, e.g. delete "OldProject".'
        else
            local full; full=$(combine_path "$target" "$loc")
            if [ ! -e "$full" ]; then
                print_error "'$full' does not exist."
            else
                local kind="file"
                [ -d "$full" ] && kind="directory"
                local permanent=0
                { has_word "$input" "permanently" || has_word "$input" "forever"; } && permanent=1
                local confirm
                if [ "$permanent" -eq 1 ]; then
                    read -e -p "$(echo -e "${C_RED}Permanently delete $kind '$full'? This CANNOT be undone. (y/N): ${C_RESET}")" confirm
                else
                    read -e -p "$(echo -e "${C_YELLOW}Delete $kind '$full'? (y/N): ${C_RESET}")" confirm
                fi
                case "$confirm" in
                    y|Y|yes|Yes|YES)
                        if [ "$permanent" -eq 1 ]; then
                            if rm -rf "$full"; then
                                print_success "$kind permanently deleted." "$full"
                            else
                                print_error "Failed to delete '$full' (check permissions)."
                            fi
                        else
                            mkdir -p "$TRASH_DIR" 2>/dev/null
                            local trash_name; trash_name="$(basename "$full")_$(date +%s)"
                            if mv "$full" "$TRASH_DIR/$trash_name"; then
                                printf '%s|%s\n' "$trash_name" "$full" >> "$TRASH_MANIFEST"
                                print_success "$kind moved to trash. Type 'undo' to restore it." "$TRASH_DIR/$trash_name"
                            else
                                print_error "Failed to delete '$full' (check permissions)."
                            fi
                        fi
                        ;;
                    *) print_info "Delete cancelled." ;;
                esac
            fi
        fi

    # --- undo the most recent trash-based delete ----------------------------
    elif has_word "$input" "undo"; then
        if [ ! -s "$TRASH_MANIFEST" ]; then
            print_warn "Nothing to undo."
        else
            local last_line tname torig
            last_line=$(tail -n 1 "$TRASH_MANIFEST")
            tname="${last_line%%|*}"
            torig="${last_line#*|}"
            if [ ! -e "$TRASH_DIR/$tname" ]; then
                print_error "That trash entry is gone (already restored or removed?)."
            elif [ -e "$torig" ]; then
                print_error "Can't restore — something already exists at '$torig'."
            elif mv "$TRASH_DIR/$tname" "$torig"; then
                remove_last_line "$TRASH_MANIFEST"
                print_success "Restored." "$torig"
            else
                print_error "Could not restore '$torig' (check permissions)."
            fi
        fi

    # --- copy / move / rename / duplicate -----------------------------------
    elif is_copy "$input" || is_move "$input"; then
        get_quoted_array "$input"
        local src="${quoted_arr[0]}" dst="${quoted_arr[1]}"
        if { [ -z "$src" ] || [ -z "$dst" ]; } && \
           [[ "$RAW_USER_INPUT" =~ (copy|copying|duplicate|duplicating|move|moving|rename|renaming)[[:space:]]+([^\"[:space:]]+)[[:space:]]+(to|as)[[:space:]]+([^\"[:space:]]+) ]]; then
            [ -z "$src" ] && src="${BASH_REMATCH[2]}"
            [ -z "$dst" ] && dst="${BASH_REMATCH[4]}"
        fi
        if [ -z "$src" ] || [ -z "$dst" ]; then
            print_error 'Please give both a source and destination, e.g. copy "a.txt" to "/tmp".'
        else
            local src_path dst_path
            src_path=$(combine_path "$src" "")
            dst_path=$(combine_path "$dst" "")
            if [ ! -e "$src_path" ]; then
                print_error "'$src_path' does not exist."
            elif is_copy "$input"; then
                if cp -r "$src_path" "$dst_path"; then
                    print_success "Copied '$src' to '$dst'." "$dst_path"
                else
                    print_error "Copy failed."
                fi
            else
                if mv "$src_path" "$dst_path"; then
                    print_success "Moved/renamed '$src' to '$dst'." "$dst_path"
                else
                    print_error "Move failed."
                fi
            fi
        fi

    # --- compress / zip ------------------------------------------------
    elif has_prefix_word "$input" "compress" || has_prefix_word "$input" "zip"; then
        get_quoted_array "$input"
        local src="${quoted_arr[0]}" dst="${quoted_arr[1]}"
        [ -z "$src" ] && src=$(last_word_fallback "$RAW_USER_INPUT")
        if [ -z "$src" ]; then
            print_error 'Please specify what to compress, e.g. compress "MyFolder".'
        else
            local src_path dst_path srcdir srcbase
            src_path=$(combine_path "$src" "")
            if [ ! -e "$src_path" ]; then
                print_error "'$src_path' does not exist."
            else
                if [ -n "$dst" ]; then dst_path=$(combine_path "$dst" ""); else dst_path="${src_path%/}.zip"; fi
                srcdir="$(dirname "$src_path")"
                srcbase="$(basename "$src_path")"
                # Pick the tool by the destination's extension, so
                # "compress X as Y.tar.bz2" / "...Y.7z" work, not just .zip.
                case "$dst_path" in
                    *.tar.bz2|*.tbz2)
                        if tar -cjf "$dst_path" -C "$srcdir" "$srcbase"; then
                            print_success "Compressed to '$dst_path'." "$dst_path"
                        else
                            print_error "Compression failed (bzip2 support missing?)."
                        fi
                        ;;
                    *.tar.gz|*.tgz)
                        if tar -czf "$dst_path" -C "$srcdir" "$srcbase"; then
                            print_success "Compressed to '$dst_path'." "$dst_path"
                        else
                            print_error "Compression failed."
                        fi
                        ;;
                    *.7z)
                        if command -v 7z >/dev/null 2>&1; then
                            if (cd "$srcdir" && 7z a -y "$dst_path" "$srcbase" >/dev/null 2>&1); then
                                print_success "Compressed to '$dst_path'." "$dst_path"
                            else
                                print_error "Compression failed."
                            fi
                        else
                            print_error "'7z' isn't installed ($(pkg_install_hint p7zip))."
                        fi
                        ;;
                    *)
                        if command -v zip >/dev/null 2>&1; then
                            # cd into the parent first so the archive stores
                            # a clean relative path ("sub/...") instead of
                            # the full absolute source path.
                            if (cd "$srcdir" && zip -r -q "$dst_path" "$srcbase"); then
                                print_success "Compressed to '$dst_path'." "$dst_path"
                            else
                                print_error "Compression failed."
                            fi
                        else
                            dst_path="${dst_path%.*}.tar.gz"
                            if tar -czf "$dst_path" -C "$srcdir" "$srcbase"; then
                                print_success "'zip' isn't installed — used tar.gz instead. Compressed to '$dst_path'." "$dst_path"
                            else
                                print_error "Compression failed."
                            fi
                        fi
                        ;;
                esac
            fi
        fi

    # --- extract / unzip -------------------------------------------------
    elif has_prefix_word "$input" "extract" || has_prefix_word "$input" "unzip" || has_prefix_word "$input" "uncompress"; then
        get_quoted_array "$input"
        local src="${quoted_arr[0]}" dst="${quoted_arr[1]:-.}"
        [ -z "$src" ] && src=$(last_word_fallback "$RAW_USER_INPUT")
        if [ -z "$src" ]; then
            print_error 'Please specify what to extract, e.g. extract "archive.zip".'
        else
            local src_path dst_path
            src_path=$(combine_path "$src" "")
            dst_path=$(resolve_path "$dst")
            if [ ! -f "$src_path" ]; then
                print_error "'$src_path' does not exist."
            else
                mkdir -p "$dst_path" 2>/dev/null
                case "$src_path" in
                    *.zip)
                        if command -v unzip >/dev/null 2>&1; then
                            if unzip -o -q "$src_path" -d "$dst_path"; then print_success "Extracted to '$dst_path'." "$dst_path"; else print_error "Extraction failed."; fi
                        else
                            print_error "'unzip' isn't installed ($(pkg_install_hint unzip))."
                        fi
                        ;;
                    *.tar.gz|*.tgz)
                        if tar -xzf "$src_path" -C "$dst_path"; then print_success "Extracted to '$dst_path'." "$dst_path"; else print_error "Extraction failed."; fi
                        ;;
                    *.tar.bz2|*.tbz2)
                        if tar -xjf "$src_path" -C "$dst_path"; then print_success "Extracted to '$dst_path'." "$dst_path"; else print_error "Extraction failed (bzip2 support missing?)."; fi
                        ;;
                    *.tar)
                        if tar -xf "$src_path" -C "$dst_path"; then print_success "Extracted to '$dst_path'." "$dst_path"; else print_error "Extraction failed."; fi
                        ;;
                    *.7z)
                        if command -v 7z >/dev/null 2>&1; then
                            if 7z x -y "$src_path" -o"$dst_path" >/dev/null 2>&1; then print_success "Extracted to '$dst_path'." "$dst_path"; else print_error "Extraction failed."; fi
                        else
                            print_error "'7z' isn't installed ($(pkg_install_hint p7zip))."
                        fi
                        ;;
                    *)
                        print_error "Unsupported archive type for '$src_path' (.zip, .tar, .tar.gz/.tgz, .tar.bz2/.tbz2, .7z only)."
                        ;;
                esac
            fi
        fi

    # --- make executable / chmod +x -----------------------------------------
    elif has_prefix_word "$input" "executable" || { has_word "$input" "chmod" && has_word "$input" "+x"; }; then
        get_quoted_array "$input"
        local target="${quoted_arr[0]}"
        # Unquoted case: the target sits BEFORE "executable" (or after
        # "chmod +x"), not at the end of the line, so last_word_fallback
        # (which assumes a trailing target) would wrongly grab the word
        # "executable" itself — use position-aware extraction instead.
        if [ -z "$target" ]; then
            if [[ "$RAW_USER_INPUT" =~ ([^\"[:space:]]+)[[:space:]]+executable ]]; then
                target="${BASH_REMATCH[1]}"
            elif [[ "$RAW_USER_INPUT" =~ chmod[[:space:]]+\+x[[:space:]]+([^\"[:space:]]+) ]]; then
                target="${BASH_REMATCH[1]}"
            fi
            case "$target" in make|makes|making|create|creates|creating|executable) target="" ;; esac
        fi
        if [ -z "$target" ]; then
            print_error 'Please specify a file, e.g. make "script.sh" executable.'
        else
            local full; full=$(combine_path "$target" "")
            if [ ! -e "$full" ]; then
                print_error "'$full' does not exist."
            elif chmod +x "$full"; then
                print_success "'$target' is now executable." "$full"
            else
                print_error "Could not change permissions on '$full'."
            fi
        fi

    # --- running processes -------------------------------------------------
    elif has_prefix_word "$input" "process" || { has_word "$input" "what" && has_word "$input" "running"; }; then
        print_info "Running processes (top 20):"
        hr
        ps aux 2>/dev/null | head -21
        hr

    # --- system-wide free disk space ----------------------------------------
    elif has_word "$input" "free" && { has_word "$input" "space" || has_word "$input" "disk"; }; then
        print_info "Disk space:"
        hr
        df -h
        hr

    # --- battery status -------------------------------------------------------
    elif has_word "$input" "battery"; then
        if [ "$(uname)" = "Darwin" ] && command -v pmset >/dev/null 2>&1; then
            print_success "$(pmset -g batt | tail -1 | sed 's/^[[:space:]]*//')"
        elif command -v upower >/dev/null 2>&1; then
            local batpath; batpath=$(upower -e 2>/dev/null | grep -i battery | head -1)
            if [ -n "$batpath" ]; then
                upower -i "$batpath" | grep -E "state|percentage"
            else
                print_warn "No battery found (desktop machine?)."
            fi
        elif [ -r /sys/class/power_supply/BAT0/capacity ]; then
            print_success "Battery: $(cat /sys/class/power_supply/BAT0/capacity)%"
        else
            print_warn "Couldn't find battery info on this system."
        fi

    # --- screenshot -----------------------------------------------------------
    elif has_word "$input" "screenshot" || { has_prefix_word "$input" "captur" && has_word "$input" "screen"; }; then
        local shot_path="$PWD/Screenshot_$(date +%Y%m%d_%H%M%S).png"
        if [ "$(uname)" = "Darwin" ] && command -v screencapture >/dev/null 2>&1; then
            screencapture "$shot_path" && print_success "Screenshot saved." "$shot_path" || print_error "Screenshot failed."
        elif command -v gnome-screenshot >/dev/null 2>&1; then
            gnome-screenshot -f "$shot_path" && print_success "Screenshot saved." "$shot_path" || print_error "Screenshot failed."
        elif command -v scrot >/dev/null 2>&1; then
            scrot "$shot_path" && print_success "Screenshot saved." "$shot_path" || print_error "Screenshot failed."
        else
            print_error "No screenshot tool found (install gnome-screenshot or scrot)."
        fi

    # --- weather --------------------------------------------------------
    elif has_word "$input" "weather"; then
        get_quoted_array "$input"
        local place="${quoted_arr[0]}"
        print_info "Checking the weather...${place:+ for $place}"
        local report; report=$(curl -s --max-time 5 "wttr.in/${place}?format=3" 2>/dev/null)
        if [ -n "$report" ]; then
            print_success "$report"
        else
            print_error "Couldn't reach the weather service — are you online?"
        fi

    # --- calculator -----------------------------------------------------------
    elif has_prefix_word "$input" "calculat" || \
         { has_word "$input" "what" && has_word "$input" "is" && [[ "$input" =~ [0-9] ]] && [[ "$input" =~ [-+*/] ]]; }; then
        local expr; expr=$(printf '%s' "$RAW_USER_INPUT" | grep -oE '[0-9. ]+[-+*/][0-9. +*/-]+' | head -1)
        if [ -z "$expr" ]; then
            print_error 'Please give me a plain expression, e.g. calculate 5 + 3, or what is 12 * 4'
        elif command -v bc >/dev/null 2>&1; then
            print_success "$expr = $(echo "$expr" | bc -l 2>/dev/null)"
        else
            print_success "$expr = $((expr))" 2>/dev/null || print_error "'bc' isn't installed and this isn't a simple integer expression."
        fi

    # --- generate a random password --------------------------------------------
    elif has_prefix_word "$input" "generat" && has_word "$input" "password"; then
        local pwlen=16
        if [[ "$input" =~ ([0-9]+)[[:space:]]*character ]]; then pwlen="${BASH_REMATCH[1]}"; fi
        local newpw
        if command -v openssl >/dev/null 2>&1; then
            newpw=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c "$pwlen")
        else
            newpw=$(head -c 256 /dev/urandom 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c "$pwlen")
        fi
        print_success "Generated password: $newpw"
        print_info "(not stored anywhere — copy it now if you need it)"

    # --- is this a git repo? -------------------------------------------------
    elif has_word "$input" "git" && has_word "$input" "repo"; then
        if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            print_success "Yes — this is a git repository." "$(git rev-parse --show-toplevel 2>/dev/null)"
        else
            print_info "No, '$PWD' is not inside a git repository."
        fi

    # --- network: my IP address ----------------------------------------------
    elif has_word "$input" "ip" && { has_word "$input" "my" || has_word "$input" "address" || has_word "$input" "what"; }; then
        print_info "Public IP address:"
        local ip; ip=$(curl -s --max-time 5 ifconfig.me 2>/dev/null)
        if [ -n "$ip" ]; then
            print_success "$ip"
        else
            print_error "Couldn't reach the internet to check — are you online?"
        fi

    # --- network: ping a host ------------------------------------------------
    elif has_word "$input" "ping"; then
        get_quoted_array "$input"
        local host="${quoted_arr[0]}"
        [ -z "$host" ] && host=$(last_word_fallback "$RAW_USER_INPUT")
        if [ -z "$host" ]; then
            print_error 'Please specify a host, e.g. ping "google.com".'
        else
            print_info "Pinging '$host' (4 packets)..."
            hr
            ping -c 4 "$host"
            hr
        fi

    # --- network: download a file --------------------------------------------
    elif has_prefix_word "$input" "download" || has_prefix_word "$input" "fetch"; then
        local url dest
        if [[ "$RAW_USER_INPUT" =~ (https?://[^[:space:]\"]+) ]]; then
            url="${BASH_REMATCH[1]}"
        fi
        get_quoted_array "$input"
        dest="${quoted_arr[0]}"
        [ "$dest" = "$url" ] && dest=""
        if [ -z "$url" ]; then
            print_error 'Please give a URL, e.g. download "https://example.com/file.pdf" to "/tmp".'
        else
            [ -z "$dest" ] && dest="$PWD"
            local dest_path
            if [ -d "$(resolve_path "$dest")" ] || [[ "$dest" == */ ]]; then
                dest_path="$(resolve_path "$dest")/$(basename "$url")"
            else
                dest_path=$(combine_path "$dest" "")
            fi
            print_info "Downloading '$url'..."
            if curl -L --fail -o "$dest_path" "$url" 2>/dev/null; then
                print_success "Downloaded." "$dest_path"
            else
                print_error "Download failed — check the URL and your connection."
            fi
        fi

    # --- reminders -----------------------------------------------------------
    elif has_word "$input" "remind"; then
        get_quoted_array "$input"
        local msg="${quoted_arr[0]:-Reminder}"
        local num="" unit=""
        if [[ "$RAW_USER_INPUT" =~ ([0-9]+)[[:space:]]*(second|minute|hour) ]]; then
            num="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"
        fi
        if [ -z "$num" ]; then
            print_error 'Usage: remind me in 5 minutes to "take a break"'
        else
            local secs="$num"
            case "$unit" in minute) secs=$((num * 60)) ;; hour) secs=$((num * 3600)) ;; esac
            (
                sleep "$secs"
                if [ "$(uname)" = "Darwin" ]; then
                    osascript -e "display notification \"$msg\" with title \"Abash Reminder\"" 2>/dev/null
                elif command -v notify-send >/dev/null 2>&1; then
                    notify-send "Abash Reminder" "$msg" 2>/dev/null
                fi
            ) &
            disown 2>/dev/null
            print_success "Reminder set for $num $unit(s) from now: \"$msg\""
        fi

    # --- count items in a folder ------------------------------------------
    # (the "&& ! lines" guard makes room for "count lines in X" below —
    # every other phrasing here behaves the same as it always has)
    elif { has_prefix_word "$input" "count" || { has_word "$input" "how" && has_word "$input" "many"; }; } && ! has_word "$input" "lines"; then
        get_quoted_array "$input"
        local target="${quoted_arr[0]:-.}"
        local path; path=$(resolve_path "$target")
        if [ -d "$path" ]; then
            local cnt; cnt=$(ls -1A "$path" 2>/dev/null | wc -l | tr -d ' \t')
            print_success "There are $cnt item(s) in '$path'." "$path"
        else
            print_error "'$path' is not a directory."
        fi

    # --- write / append to a file -------------------------------------------
    elif { has_prefix_word "$input" "write" || has_prefix_word "$input" "append"; } && has_word "$input" "to"; then
        get_quoted_array "$input"
        local content="${quoted_arr[0]}" target="${quoted_arr[1]}"
        if [ -z "$content" ] || [ -z "$target" ]; then
            print_error 'Usage: write "text" to "file.txt"  (or: append "text" to "file.txt")'
        else
            local full; full=$(combine_path "$target" "")
            mkdir -p "$(dirname "$full")" 2>/dev/null
            if has_prefix_word "$input" "append"; then
                if printf '%s\n' "$content" >> "$full"; then
                    print_success "Appended to '$target'." "$full"
                else
                    print_error "Could not write to '$full'."
                fi
            else
                if printf '%s\n' "$content" > "$full"; then
                    print_success "Wrote to '$target'." "$full"
                else
                    print_error "Could not write to '$full'."
                fi
            fi
        fi

    # --- search TEXT inside files — distinct from searching for a file BY
    #     NAME, handled later. Must stay ahead of that branch, since both
    #     use "find"/"search". ------------------------------------------------
    elif has_prefix_word "$input" "grep" || \
         { has_word "$input" "word" && has_prefix_word "$input" "find"; } || \
         { has_word "$input" "text" && has_prefix_word "$input" "search"; }; then
        get_quoted_array "$input"
        local pattern="${quoted_arr[0]}" target="${quoted_arr[1]:-.}"
        if [ -z "$pattern" ]; then
            print_error 'Please specify text to search for, e.g. find the word "Error" in "app.log".'
        else
            local path; path=$(resolve_path "$target")
            print_info "Searching for '$pattern' inside files under '$path'..."
            local results; results=$(grep -rn -- "$pattern" "$path" 2>/dev/null | head -50)
            if [ -n "$results" ]; then
                echo "$results"
                print_success "Search complete." "$path"
            else
                print_warn "No matches found for '$pattern' in '$path'."
            fi
        fi

    # --- create file / touch ------------------------------------------------
    elif { has_prefix_word "$input" "creat" || has_prefix_word "$input" "mak" || has_prefix_word "$input" "touch"; } && has_word "$input" "file"; then
        get_quoted_array "$input"
        local fname="${quoted_arr[0]}"
        [ -z "$fname" ] && fname=$(last_word_fallback "$RAW_USER_INPUT")
        local loc; loc=$(extract_location "$input")
        if [ -z "$fname" ]; then
            print_error 'Please specify a file name, e.g. create file "notes.txt".'
        else
            [ -z "$loc" ] && loc="$PWD"
            loc=$(resolve_path "$loc")
            mkdir -p "$loc" 2>/dev/null
            if [ -e "$loc/$fname" ]; then
                print_warn "File '$fname' already exists at '$loc'."
            elif touch "$loc/$fname"; then
                print_success "File '$fname' created." "$loc"
            else
                print_error "Could not create '$fname' at '$loc'."
            fi
        fi

    # --- cat / show contents ------------------------------------------------
    elif has_word "$input" "cat" || \
         { is_show "$input" && has_word "$input" "contents"; } || \
         { has_prefix_word "$input" "read" && has_word "$input" "file"; }; then
        get_quoted_array "$input"
        local fname="${quoted_arr[0]}"
        [ -z "$fname" ] && fname=$(last_word_fallback "$RAW_USER_INPUT")
        local loc; loc=$(extract_location "$input")
        if [ -z "$fname" ]; then
            print_error 'Please specify a file, e.g. show contents of "notes.txt".'
        else
            local full; full=$(combine_path "$fname" "$loc")
            if [ -f "$full" ]; then
                print_info "Contents of '$full'"
                hr
                cat "$full"
                hr
            else
                print_error "File '$full' not found."
            fi
        fi

    # --- what kind of file is this? -------------------------------------
    elif { has_word "$input" "kind" || has_prefix_word "$input" "type"; } && has_word "$input" "file"; then
        get_quoted_array "$input"
        local fname="${quoted_arr[0]}"
        [ -z "$fname" ] && fname=$(last_word_fallback "$RAW_USER_INPUT")
        if [ -z "$fname" ]; then
            print_error 'Please specify a file, e.g. what kind of file is "notes.txt".'
        else
            local full; full=$(combine_path "$fname" "")
            if [ -e "$full" ]; then
                print_success "$(file -b "$full" 2>/dev/null)" "$full"
            else
                print_error "'$full' not found."
            fi
        fi

    # --- count lines in a file -----------------------------------------------
    elif has_word "$input" "lines" && { has_prefix_word "$input" "count" || { has_word "$input" "how" && has_word "$input" "many"; }; }; then
        get_quoted_array "$input"
        local fname="${quoted_arr[0]}"
        [ -z "$fname" ] && fname=$(last_word_fallback "$RAW_USER_INPUT")
        if [ -z "$fname" ]; then
            print_error 'Please specify a file, e.g. how many lines in "notes.txt".'
        else
            local full; full=$(combine_path "$fname" "")
            if [ -f "$full" ]; then
                print_success "$(wc -l < "$full" | tr -d ' ') line(s) in '$fname'." "$full"
            else
                print_error "'$full' not found."
            fi
        fi

    # --- combine/merge files -------------------------------------------------
    elif has_prefix_word "$input" "combin" || has_prefix_word "$input" "merg"; then
        get_quoted_array "$input"
        if [ "${#quoted_arr[@]}" -lt 3 ]; then
            print_error 'Usage: combine "a.txt" and "b.txt" into "c.txt"'
        else
            local out="${quoted_arr[$((${#quoted_arr[@]} - 1))]}"
            local out_path; out_path=$(combine_path "$out" "")
            local i part_path ok=1
            : > "$out_path"
            for ((i = 0; i < ${#quoted_arr[@]} - 1; i++)); do
                part_path=$(combine_path "${quoted_arr[$i]}" "")
                if [ -f "$part_path" ]; then
                    cat "$part_path" >> "$out_path"
                else
                    print_error "'$part_path' not found."
                    ok=0
                fi
            done
            [ "$ok" -eq 1 ] && print_success "Combined into '$out'." "$out_path"
        fi

    # --- search / find -------------------------------------------------
    elif has_prefix_word "$input" "search" || has_prefix_word "$input" "find"; then
        get_quoted_array "$input"
        local qname="${quoted_arr[0]}"
        [ -z "$qname" ] && qname=$(last_word_fallback "$RAW_USER_INPUT")
        local loc; loc=$(extract_location "$input")
        [ -z "$loc" ] && loc="$PWD"
        loc=$(resolve_path "$loc")
        if [ -z "$qname" ]; then
            print_error 'Please specify what to search for, e.g. search for "notes.txt".'
        else
            print_info "Searching for '*$qname*' in '$loc'..."
            local results
            results=$(find "$loc" -iname "*$qname*" 2>/dev/null)
            if [ -n "$results" ]; then
                echo "$results"
                print_success "Search complete." "$loc"
            else
                print_warn "No matches found for '$qname' in '$loc'."
            fi
        fi

    # --- disk usage / size of a path ---------------------------------------
    elif has_word "$input" "size" || has_word "$input" "usage" || has_word "$input" "du"; then
        get_quoted_array "$input"
        local target="${quoted_arr[0]:-.}"
        local path; path=$(resolve_path "$target")
        if [ -e "$path" ]; then
            local size; size=$(du -sh "$path" 2>/dev/null | awk '{print $1}')
            print_success "Size of '$path': ${size:-unknown}" "$path"
        else
            print_error "'$path' not found."
        fi

    # --- tree / structure -------------------------------------------------
    elif has_word "$input" "tree" || { is_show "$input" && has_prefix_word "$input" "structure"; }; then
        get_quoted_array "$input"
        local target="${quoted_arr[0]:-.}"
        local path; path=$(resolve_path "$target")
        if [ -d "$path" ]; then
            print_info "Structure of '$path'"
            hr
            if command -v tree >/dev/null 2>&1; then
                tree -L 2 "$path"
            else
                find "$path" -maxdepth 2 | sed "s#$path#.#"
            fi
            hr
            print_success "Done." "$path"
        else
            print_error "'$path' is not a directory."
        fi

    # --- make/create directory(ies)/folder(s) -------------------------------
    elif { has_prefix_word "$input" "mak" || has_prefix_word "$input" "creat"; } && \
         { has_prefix_word "$input" "director" || has_prefix_word "$input" "folder"; }; then

        local name_str; name_str=$(extract_name "$input")
        local loc_str;  loc_str=$(extract_location "$input")
        local count_word=""
        if [[ "$input" =~ (make|create)[[:space:]]+(eighteen|eleven|fifteen|fourteen|nineteen|seventeen|sixteen|thirteen|twelve|twenty|eight|five|four|nine|one|seven|six|ten|three|two|an|a|[0-9]+)([[:space:]]|$) ]]; then
            count_word="${BASH_REMATCH[2]}"
        fi

        if [ -n "$name_str" ]; then
            name_str=$(printf '%s' "$name_str" | sed 's/[[:space:]]*,[[:space:]]*/,/g')
            name_str=$(trim "$name_str")
        fi

        local name_count=0
        if [ -n "$name_str" ]; then
            local -a tmp_names=()
            local OLDIFS="$IFS"
            IFS=','
            read -r -a tmp_names <<< "$name_str"
            IFS="$OLDIFS"
            name_count=${#tmp_names[@]}
        fi

        local count
        if [ -n "$count_word" ]; then
            count=$(word2number "$count_word")
            if [ -z "$count" ]; then
                print_warn "Couldn't understand the number '$count_word' — defaulting to 1."
                count=1
            fi
        elif [ "$name_count" -gt 0 ]; then
            count=$name_count
        elif has_word "$input" "folders" || has_word "$input" "directories"; then
            local ans
            read -e -p "$(echo -e "${C_CYAN}How many folders would you like to create? (default 1): ${C_RESET}")" ans
            [ -z "$ans" ] && ans=1
            count=$(word2number "$ans")
            [ -z "$count" ] && count=1
        else
            count=1
        fi

        if [ -z "$loc_str" ]; then
            local ans_loc
            read -e -p "$(echo -e "${C_CYAN}Where should it be created? (Enter for current directory: $PWD): ${C_RESET}")" ans_loc
            loc_str="${ans_loc:-$PWD}"
        fi
        loc_str=$(resolve_path "$loc_str")

        create_directories "$name_str" "$count" "$loc_str"

    # --- raw mkdir ------------------------------------------------------
    elif [[ "$input" =~ mkdir[[:space:]]+(.+)$ ]]; then
        local dir_name="${BASH_REMATCH[1]}"
        if [ -d "$dir_name" ]; then
            print_warn "Directory '$dir_name' already exists in the current location."
        elif mkdir "$dir_name"; then
            print_success "Directory '$dir_name' created." "$PWD"
        else
            print_error "Could not create '$dir_name'."
        fi

    # --- ls -all / -la  (must be checked BEFORE "-a", "-l", plain "ls") ----
    # Explicit { } grouping: left-to-right && / || evaluation already
    # produces the intended (ls && flag) || (show && word) grouping, but
    # spelling it out removes any doubt and protects future edits.
    elif { has_word "$input" "ls" && { has_word "$input" "-all" || has_word "$input" "-la" || has_word "$input" "-al"; }; } || \
         { is_show "$input" && has_word "$input" "all"; }; then
        get_quoted_array "$input"
        local loc; loc=$(extract_location "$input")
        [ -z "$loc" ] && loc="."
        if [ -d "$loc" ]; then
            print_info "Listing all (hidden + detailed) in: $loc"
            hr
            if [ "$(uname)" = "Darwin" ]; then ls -Gla "$loc"; else ls --color=auto -la "$loc"; fi
            hr
        else
            print_error "The specified location '$loc' does not exist."
        fi

    # --- ls -a (hidden) ------------------------------------------------
    elif { has_word "$input" "ls" && has_word "$input" "-a"; } || \
         { is_show "$input" && has_word "$input" "hidden"; }; then
        get_quoted_array "$input"
        local loc; loc=$(extract_location "$input")
        [ -z "$loc" ] && loc="."
        if [ -d "$loc" ]; then
            print_info "Listing hidden entries in: $loc"
            hr
            if [ "$(uname)" = "Darwin" ]; then ls -Ga "$loc"; else ls --color=auto -a "$loc"; fi
            hr
        else
            print_error "The specified location '$loc' does not exist."
        fi

    # --- ls -l (detailed) ------------------------------------------------
    elif { has_word "$input" "ls" && has_word "$input" "-l"; } || \
         { is_show "$input" && has_word "$input" "full"; }; then
        get_quoted_array "$input"
        local loc; loc=$(extract_location "$input")
        [ -z "$loc" ] && loc="."
        if [ -d "$loc" ]; then
            print_info "Listing (detailed) in: $loc"
            hr
            if [ "$(uname)" = "Darwin" ]; then ls -Gl "$loc"; else ls --color=auto -l "$loc"; fi
            hr
        else
            print_error "The specified location '$loc' does not exist."
        fi

    # --- plain ls — checked LAST because it's the least specific -----------
    elif has_word "$input" "ls" || { is_show "$input" && has_word "$input" "list"; }; then
        get_quoted_array "$input"
        local loc; loc=$(extract_location "$input")
        [ -z "$loc" ] && loc="."
        if [ -d "$loc" ]; then
            print_info "Listing: $loc"
            hr
            if [ "$(uname)" = "Darwin" ]; then ls -G "$loc"; else ls --color=auto "$loc"; fi
            hr
        else
            print_error "The specified location '$loc' does not exist."
        fi

    # --- whoami -------------------------------------------------------
    elif has_word "$input" "whoami" || { has_word "$input" "who" && has_word "$input" "am"; }; then
        print_success "$(whoami)"

    # --- date/time ------------------------------------------------------
    elif has_word "$input" "date" || has_word "$input" "time"; then
        print_success "$(date)"

    else
        return 127
    fi
}

# ---------------------------------------------------------------------------
# 9. Best-effort Tab completion. Path completion via readline always works
#     through `read -e`. Keyword completion additionally needs
#     READLINE_LINE/POINT, which only exist on Bash 4+, so it's only enabled
#     there — it degrades safely (silently skipped) on Bash 3.2 (macOS's
#     default /bin/bash).
# ---------------------------------------------------------------------------

ABASH_KEYWORDS="help commands make create directory directories folder folders location locations name names go back cd navigate jump change open launch play pwd where current show display list full hidden all delete remove erase trash undo permanently rm copy duplicate cp move rename mv touch file cat read search find grep word text tree size usage free disk space process processes running count how many compress zip extract unzip executable chmod write append alias as ip ping download fetch clear cls history whoami date time exit quit close terminate"

abash_tab_complete() {
    local line="$READLINE_LINE" point="$READLINE_POINT"
    local head="${line:0:$point}" tail="${line:$point}"
    local cur="${head##* }" prefix="${head% *}"
    [ "$prefix" = "$head" ] && prefix=""

    local -a matches=()
    local w
    for w in $ABASH_KEYWORDS; do
        case "$w" in "$cur"*) matches+=("$w") ;; esac
    done

    if [ "${#matches[@]}" -eq 0 ]; then
        while IFS= read -r f; do matches+=("$f"); done < <(compgen -f -- "$cur")
    fi

    if [ "${#matches[@]}" -eq 1 ]; then
        if [ -n "$prefix" ]; then
            READLINE_LINE="$prefix ${matches[0]}$tail"
            READLINE_POINT=$(( ${#prefix} + 1 + ${#matches[0]} ))
        else
            READLINE_LINE="${matches[0]}$tail"
            READLINE_POINT=${#matches[0]}
        fi
    elif [ "${#matches[@]}" -gt 1 ]; then
        printf '\n%s\n' "${matches[*]}"
    fi
}

if [ -t 0 ] && [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
    bind -x '"\t": abash_tab_complete' 2>/dev/null
fi

# ---------------------------------------------------------------------------
# 10. Main REPL
# ---------------------------------------------------------------------------

run_repl() {
    HISTFILE="$HOME/.abash_history"
    touch "$HISTFILE" 2>/dev/null
    history -r "$HISTFILE" 2>/dev/null

    TRASH_DIR="$HOME/.abash_trash"
    TRASH_MANIFEST="$TRASH_DIR/.manifest"
    mkdir -p "$TRASH_DIR" 2>/dev/null
    touch "$TRASH_MANIFEST" 2>/dev/null

    ALIAS_FILE="$HOME/.abash_aliases"
    touch "$ALIAS_FILE" 2>/dev/null

    trap 'history -w "$HISTFILE" 2>/dev/null' EXIT
    trap 'echo; print_info "Interrupted."; history -w "$HISTFILE" 2>/dev/null; exit 0' INT

    print_banner
    print_info "Type 'help' for commands. Anything else is tried as a real shell command."

    while true; do
        echo -e "${C_DIM}+-[${C_GREEN}$(whoami)${C_RESET}${C_DIM}]-[${C_YELLOW}$(shorten_path)${C_RESET}${C_DIM}]-[${C_MAGENTA}$(date '+%H:%M:%S')${C_RESET}${C_DIM}]${C_RESET}"
        user_input=""
        if ! read -e -p "$(echo -e "${C_DIM}\`-> ${C_RESET}")" user_input; then
            # EOF on stdin (Ctrl-D, or a closed/redirected pipe) — exit
            # cleanly instead of looping at zero delay forever.
            echo
            print_success "Goodbye! See you later."
            break
        fi

        if [ -z "$(trim "$user_input")" ]; then
            continue
        fi

        history -s "$user_input"

        # Expand a saved alias before anything else touches the line.
        local alias_expanded
        alias_expanded=$(lookup_alias "$user_input")
        if [ -n "$alias_expanded" ]; then
            print_info "Alias '$user_input' -> $alias_expanded"
            user_input="$alias_expanded"
        fi
        RAW_USER_INPUT="$user_input"

        # "!" always forces raw shell execution, bypassing natural language.
        case "$user_input" in
            "!"*)
                try_raw_command "$user_input"
                continue
                ;;
        esac

        corrected_input=$(autocorrect_user_input "$user_input")

        if has_word "$corrected_input" "exit" || has_word "$corrected_input" "quit" || \
           has_word "$corrected_input" "close" || has_word "$corrected_input" "terminate"; then
            print_success "Goodbye! See you later."
            break
        fi

        abash "$corrected_input"
        if [ $? -eq 127 ]; then
            if ! try_raw_command "$user_input"; then
                print_error "Sorry, I don't understand that. Type 'help', or try '!<command>' to run it as raw shell."
            fi
        fi
    done
}

# ---------------------------------------------------------------------------
# 11. Entry point
# ---------------------------------------------------------------------------

require_login || exit 1
run_repl
