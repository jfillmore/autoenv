#  ,.-'`'-={[** lib.sh **]}=-'`'-.,
# .--------------------------------.
# | breathe life into bash scripts |
# '--------------------------------'
#
# - flow    - easy failure, dry-run/verbose command wrapper
# - logging - print colorful, tagged messages to stderr
# - choices - prompts/menus for choices, quick input matching against lists
# - misc    - colors/colorful text

# - TODO -
# - narrow fuzzy match if multiple matched

# set our logging tag based on env var, param, or finally whoever sourced us
LIB_TAG="${LIB_TAG:-${1:-$(basename "$0")}}"


# exit with an error, and optional error message
lib_fail() {
    lib_log_error "${1-unknown error}"
    exit ${2:-1}
}


# run a command unless LIB_DRYRUN=1; always prints shell quoted commands+args
# when LIB_VERBOSE=1
lib_cmd() {
    if [ ${LIB_DRYRUN:-0} -eq 1 ]; then
        echo -e "\033[0;33m# $(printf "'%s' " "$@")\033[0m" >&2
    else
        [ ${LIB_VERBOSE:-0} -eq 1 ] \
            && echo -e "\033[0;33m# $(printf "'%s' " "$@")\033[0m" >&2
        "$@"
    fi
}


# log a tagged informational message, optionally of a specific color code/name
# $1 = message
# $2 = color (dafault: dark grey)
lib_log() {
    local clr="${2:-0;34}"
    [ "${clr//;/}" = "$clr" ] && clr=$(lib_color "$clr")
    echo -e "\033[1;30m# ($LIB_TAG) \033[${clr}m${1:-}\033[0m" >&2
}


# log a tagged error message, optionally of a specific color code/name
# $1 = message
# $2 = color (default: pink)
lib_log_error() {
    local clr="${2:-0;31}"
    local error_label="${3:-error}"
    [ "${clr//;/}" = "$clr" ] && clr=$(lib_color "$clr")
    echo -e "\033[1;31m# ($LIB_TAG $error_label) \033[${clr}m${1:-}\033[0m" >&2
}


# log something, optionally of a specific color code/name
# $1 = message
# $2 = color (default: white)
lib_log_raw() {
    local clr="${2:-0;37}"
    [ "${clr//;/}" = "$clr" ] && clr=$(lib_color "$clr")
    echo -e "\033[${clr}m${1:-}\033[0m" >&2
}


# echo back stdin, minus any color codes
# e.g.
# $ echo -e "\033[1;32mfoo\033[0mbar" | lib_strip_color
# foobar
lib_strip_color() {
    sed $'s,\x1b\\[[0-9;]*[a-zA-Z],,g'
}

# echo back user input, optionally after validating it
# $1  = prompt to give
# $2+ = -$a|--$arg OR valid matches to enforce, if any
# args:
# -m|--menu, -f*|--fuzzy*, -n|--numchars X, -b|--break
lib_prompt() {
    local errors
    local fuzzy_ignore
    local fuzzy_match=0
    local i
    local line_break=''
    local match=
    local match_rv
    local matched_input
    local matches=()
    local msg=
    local num_chars=0
    local opts=
    local opts_msg=
    local read_args=()
    local show_menu=0
    local silent=0
    local user_input

    # gatcher up matches for the prompt and validation later
    while [ $# -gt 0 ]; do
        if [ "${1:0:1}" = '-' ]; then
            case "$1" in
                -b|--break):
                    line_break="\n"
                    ;;
                -f*|--fuzzy*)
                    fuzzy_match=1
                    # if we're followed by some chars then those are ones we ignore
                    [ "${1:0:2}" == '--' ] \
                        && fuzzy_ignore="${1:7}" \
                        || fuzzy_ignore="${1:2}"
                    ;;
                -m|--menu)
                    show_menu=1
                    ;;
                -n|--numchars)
                    [ $# -ge 2 ] || {
                        echo "Missing lib_prompt arg to -n|numchars"
                        return 1
                    }
                    num_chars=$2
                    shift
                    ;;
                -s|--silent)
                    silent=1
                    ;;
                *)
                    echo "Unknown lib_prompt arg: $1" >&2
                    return 1
                    ;;
            esac
        else
            [ -z "$msg" ] \
                && msg="$1" \
                || {
                    [ -n "$1" ] && matches+=("$1")
                }
        fi
        shift
    done
    [ ${#matches[*]} -gt 0 ] && {
        [ $show_menu -eq 0 ] \
            && opts=" (${matches[0]}" \
            || opts="\n  * ${matches[0]}"
        for ((i=1; i<${#matches[*]}; i++)); do
            [ $show_menu -eq 0 ] \
                && opts="$opts|${matches[$i]}" \
                || opts="$opts\n  * ${matches[$i]}"
        done
        [ $show_menu -eq 0 ] && opts="$opts)"
    }
    [ $fuzzy_match -eq 1 -a ${#matches[*]} -eq 0 ] && {
        echo "lib_prompt error: You must provide matches to use --fuzzy" >&2
        return 1
    }
    [ $silent -eq 1 ] && read_args+=(-s)
    [ $num_chars != '0' ] && read_args+=(-n $num_chars)
    # read and optionally validate the input until we get something right
    [ $fuzzy_match -eq 1 ] && opts_msg=" (prefix match allowed)"
    [ $show_menu -eq 0 ] \
        && msg="$msg$opts_msg\033[0;33m$opts\033[0m" \
        || msg="Options$opts_msg:\033[1;34m$opts\033[0;0m\n$msg"
    while [ -z "$match" ]; do
        error=
        echo -en "$line_break$msg \033[1;30m>\033[0m " >&2
        if [ "${#read_args[*]}" -eq 0 ]; then
            read user_input
        else
            read "${read_args[@]}" user_input
        fi
        [ $num_chars -gt 0 -o $silent -eq 1 ] && echo >&2
        if [ $fuzzy_match -eq 0 ]; then
            for ((i=0; i<${#matches[*]}; i++)); do
                [ "$user_input" = "${matches[i]}" ] && {
                    match="$user_input"
                    break
                }
            done
        else
            matched_input="$(lib_match_one "$user_input" -i "$fuzzy_ignore" -- "${matches[@]}")"
            match_rv=$?
            if [ $match_rv -eq 0 ]; then
                match="$matched_input"
                break
            elif [ $match_rv -eq 1 ]; then
                error="no valid option found for '$user_input'" >&2
            else
                error="multiple matches found for '$user_input': ${matched_input:0:92}..." >&2
            fi
        fi
        [ ${#matches[*]} -eq 0 ] && match="$user_input"
        [ ${#match} -eq 0 ] \
            && echo -e "\nPlease try again: $error\n" >&2
    done
    echo "$match"
}


# returns 0 if >one< match for /^input/ is found and always prints the matched
# values; otherwise returns 1 if none/error, or 2+ if multiple matched
# $1    = input to search matches for
# $2..n = params
#   -i|--ignore CHARS    chars to ignore during matching
#   -s|--shortest         allow multiple matches, but return the shortest one
#   -f|--fuzzy           match anywhere within the string, not just prefix
# --    = delimiter to start providing match values
# $n... = match values
lib_match_one() {
    [ $# -ge 3 ] || {
        lib_log_error "at least three arguments expected to lib_match_one: input chars_to_ignore match_tmatch1 ... matchN"
        return 1
    }
    local matches=()
    local i
    local input=
    local ignore=
    local match_shortest=0
    local match_fuzzy=0
    local input_len=
    local to_match=()
    local best_match=
    local match=

    # collect params
    while [ $# -gt 0 ]; do
        case "$1" in
            -f|--fuzzy)
                match_fuzzy=1
                ;;
            -i|--ignore)
                [ $# -ge 2 ] || {
                    lib_log_error "missing parameter to lib_match_one -i|--ignore"
                    return 1
                }
                ignore="$2"
                shift
                ;;
            -s|--shortest)
                match_shortest=1
                ;;
            --)
                shift
                to_match=("$@")
                while [ $# -gt 1 ]; do shift; done
                ;;
            *)
                [ -n "$input" ] && {
                    lib_log_error "input of '$input' already given"
                    return 1
                }
                input="$1"
                input_len=${#input}
            ;;
        esac
        shift
    done

    # collect matches
    for ((i=0; i<${#to_match[*]}; i++)); do
        match=$(echo "${to_match[i]}" | tr -d "$ignore")
        [ -n "$match" ] || continue
        if [ $match_fuzzy -eq 1 ]; then
            [ "${match//$input}" != "$match" ] && matches+=("$match")
        else
            [ "$input" = "${match:0:input_len}" ] && matches+=("$match")
        fi
    done

    # no matches? easy out
    [ ${#matches[*]} -eq 0 ] && return 1
    # print match(es) and proper retval
    if [ $match_shortest -eq 1 ]; then
        best_match="${matches[0]}"
        for ((i=1; i<${#matches[*]}; i++)); do
            match="${matches[i]}"
            # the first seen shortest match wins
            [ ${#match} -lt ${#best_match} ] && best_match="$match"
        done
        echo "$best_match"
        return 0
    else
        # print matches and hopefully it was just one
        echo "${matches[@]}"
        [ ${#matches[*]} -eq 1 ] && return 0 || return ${#matches[*]}
    fi
}


# quickly confirm whether or not to do an action; return 1 if not. If a command
# is given, automatically runs the command.
# $1  = message
# $2+ = command + args to run, if true
lib_confirm() {
    local msg
    local choice
    
    [ $# -ge 1 ] || {
        lib_log_error "Missing message to lib_confirm as first arg"
        return 1
    }
    msg="$1"; shift
    choice=$(lib_prompt "$(lib_color white "$msg")" -n 1 y n) || return 1
    [ "$choice" = y ] && {
        # got a command? run it!
        [ $# -ge 1 ] && {
            "$@"
            return $?
        }
        return 0
    }
    return 1
}


# return 0 if any args prior to -- or == are found the rest of the args; else 1
# if so and == is the pivot, the index (0-based) of the match and item matched
# are printed to stdout separated by tabs
# e.g.:
# 1) lib_in_list me you == at the bar is me && echo "saw me or you"
#    > 4	me
#    > saw me or you
# 2) lib_in_list me you -- at the bar is sue and tom || echo "did not see me or you"
#    > did not see me or you
# 3) lib_in_list the foo -- at the bar is sue and tom && echo "saw the or foo"
#    > saw the or foo
lib_in_list() {
    local wanted=()
    local to_search=()
    local echo
    local pivot=
    local i j

    # sort out within params what we're searching for vs matching against
    while [ $# -gt 0 ]; do
        case "$1" in
            --|==)
                [ -z "$pivot" ] || {
                    lib_log_error "multiple pivots given; just one is wanted"
                    return 2
                }
                pivot="$1"
                ;;
            *)
                [ -z "$pivot" ] \
                    && wanted+=("$1") \
                    || to_search+=("$1")
        esac
        shift
    done

    # find and possibly print the matched item/index
    [ ${#wanted[*]} -eq 0 -o "${#to_search[*]}" -eq 0 ] && return 1
    for ((i=0; i<${#wanted[*]}; i++)); do
        for ((j=0; j<${#to_search[*]}; j++)); do
            [ "${wanted[i]}" = "${to_search[j]}" ] &&  {
                # TAB delimited, not space! easier to `cut`
                [ "$pivot" = '==' ] && echo "$j	${wanted[i]}"
                return 0
            }
        done
    done
    return 1
}


# get the index position for an item in a string list
# returns an empty string and non-0 if not found
# $1=list string
# $2=item to search for
# $3=delimiter (optional)
lib_list_index() {
    local list="$1"
    local search="$2"
    local sep="${3:-:}"
    local i=0
    local item
    (
        IFS="$sep"
        for item in $list; do
            [ "$item" = "$search" ] && {
                echo $i
                exit 0
            }
            let i+=1
        done
        exit 1
    )
    return $?
}


# update a list with a new item at the position specified
# $1=list
# $2=item to insert
# $3=position to insert at (default: last)
# $4=delimiter (optional)
lib_list_update() {
    local list="$1"
    local insert="$2"
    local pos="{$3:-}"
    local sep="${$4:-:}"
    local final_list=''
    local item
    local origIFS="$IFS"
    IFS="$sep"
    for item in $list; do
        [ $i -eq $pos ] && {
            [ $i -eq 0 ] \
                && final_list="$insert$sep$item" \
                || final_list="$final_list$sep$insert$sep$item"
        } || {
            [ $i -eq 0 ] \
                && final_list="$item" \
                || final_list="$final_list$sep$item"
        }
        let i+=1
    done
    IFS="$origIFS"
    echo "$final_list"
}

# get a color code based on name or print a message with a certain color code/name
# $1 = bash color code (e.g. 0;31) or nickname
# $2 = optional text to print with the color; otherwise ethe code is printed
# $3 = optional bash color code to reset to after if text is given; default=reset
lib_color() {
    local clr="$1"
    local msg="${2:-}"
    local clr_end="${3:-}"
    local colors=(
        black red green yellow blue purple cyan lightgrey reset
        darkgrey pink lime lemon lightblue fushia lightcyan white reset
    )
    local color_codes=(
        '0;30' '0;31' '0;32' '0;33' '0;34' '0;35' '0;36' '0;37' '0'
        '1;30' '1;31' '1;32' '1;33' '1;34' '1;35' '1;36' '1;37' '0'
    )
    local i
    # map names to codes if needed
    [ "${clr//;/}" = "$clr" ] && {
        i=$(lib_in_list "$clr" == "${colors[@]}" | cut -f 1)
        clr="${color_codes[${i:-8}]}"
    }
    # no message given? just return the color code back
    if [ -z "$msg" ]; then
        echo "$clr"
    else
        # otherwise print a colorized message
        clr="\033[${clr}m"
        [ -n "$clr_end" ] || clr_end=0  # reset by default
        [ "${clr_end//;/}" = "$clr_end" ] && {
            i=$(lib_in_list "$clr_end" == "${colors[@]}" | cut -f 1)
            clr_end="${color_codes[${i:-8}]}"
        }
        clr_end="\033[${clr_end}m"
        echo "${clr}${msg}${clr_end}"
    fi
}

# print columns of data, optionally using a prefix and suffex set of chars...
# fun, but efficiency is rather limited.
#
# usage: lib_cols [ARGS] item [item2 ... itemN]
#
# -c|--color COLOR_OR_CODE   - use the style given for the items
# -d|--delimiter STRING      - use a different delimeter than a double space
# -h|--header HEADER
# -m|--min                   - don't try to fit the full term width; if single
#                              row, don't pad to max value width
# -p|--prefix PREFIX
# -s|--suffix SUFFIX
# -w|--width NUM
# $N = message strings
#
# e.g.:, assuming a super terminal width of ~55 chars
# $ lib_colors -p '-={ ' -h 'Food:' -s ' }=-' grape apple pear ... blah
# -={ Food: grape apple pear ...                      }=-
# -={       ... blah                                  }=-
lib_cols() {
    local header=
    local prefix=
    local suffix=
    local color=0
    local min=0
    local header_raw prefix_raw suffix_raw
    local msgs=()
    local msg_w=0
    local delim='  '
    local delim_raw
    local single_row=0
    local i style_w row_w cols msg_per_col max_col_w=0 extra_space=0 msg_space=0
    local row=0 is_last_col=0 is_last_val=0 space cols_missing

    cols=$(tput cols) || {
        lib_log_error "Failed to determine terminal width"
        return 1
    }

    while [ $# -gt 0 ]; do
        case "$1" in
            -c|--color)
                [ $# -ge 2 ] || {
                    lib_log_error "Missing lib_cols param to --color|-c"
                    return 1
                }
                color="$2"
                [ "${color//;/}" = "$color" ] && color=$(lib_color "$color")
                shift
                ;;
            -d|--delimeter)
                [ $# -ge 2 ] || {
                    lib_log_error "Missing lib_cols param to --delimeter|-d"
                    return 1
                }
                delim="$2"
                shift
                ;;
            -h|--header)
                [ $# -ge 2 ] || {
                    lib_log_error "Missing lib_cols param to --header|-h"
                    return 1
                }
                header="$2"
                shift
                ;;
            -p|--prefix)
                [ $# -ge 2 ] || {
                    lib_log_error "Missing lib_cols param to --prefix|-p"
                    return 1
                }
                prefix="$2"
                shift
                ;;
            -m|--min)
                min=1
                ;;
            -s|--suffix)
                [ $# -ge 2 ] || {
                    lib_log_error "Missing lib_cols param to --suffix|-s"
                    return 1
                }
                suffix="$2"
                shift
                ;;
            -w|--width)
                [ $# -ge 2 ] || {
                    lib_log_error "Missing lib_cols param to --width|-w"
                    return 1
                }
                cols="$2"
                shift
                ;;
            *)
                msgs+=("$1")
                # track the longest value
                [ ${#1} -gt $max_col_w ] && max_col_w=${#1}
                # keep a running total of total width
                msg_w=$((msg_w + ${#1}))
                ;;
        esac
        shift
    done
    [ ${#msgs[*]} -eq 0 ] && return

    # we need raw char counts to do terminal width math right
    header_raw="$(echo -e "$header" | lib_strip_color)"
    prefix_raw="$(echo -e "$prefix" | lib_strip_color)"
    suffix_raw="$(echo -e "$suffix" | lib_strip_color)"
    delim_raw="$(echo -e "$delim" | lib_strip_color)"
    msg_w=$(( msg_w + ((${#msgs[*]} - 1) * ${#delim_raw}) ))
    # based on max_col_w, how many columns do we get?
    style_w=$((${#header_raw} + ${#prefix_raw} + ${#suffix_raw}))
    # how much usable space do we have for messages?
    row_w=$((cols - style_w))
    space="$(printf '%0.s ' $(seq 1 $row_w))"  # faster than doing this over and over
    # adding one for delim space after each col, and +more as the last won't have one
    msg_per_col=$(( (row_w + ${#delim_raw}) / (max_col_w + ${#delim_raw}) ))
    if [ $min -eq 0 ]; then
        extra_space=$(( (row_w + ${#delim_raw}) - (msg_per_col * (max_col_w + ${#delim_raw})) ))
    else
        # can we fit all on one row?
        [ $msg_w -le $row_w ] && {
            single_row=1
            msg_per_col=${#msgs[*]}
        }
    fi
    [ $extra_space -gt 0 ] && suffix="\033[${color}m${space:0:extra_space}\033[0m$suffix"

    # print out all the messages into cols w/ prefix + header ... suffix
    for ((i=0; i<${#msgs[*]}; i++)); do
        msg="${msgs[i]}"
        # last columns get spacing handled differently
        [ $((i % msg_per_col)) = $((msg_per_col - 1)) ] \
            && is_last_col=1 \
            || is_last_col=0
        [ $((i+1)) = ${#msgs[*]} ] \
            && is_last_val=1 \
            || is_last_val=0
        # print prefix/headers or spacing at the start of each row
        [ $((i % msg_per_col)) -eq 0 ] && {
            if [ $row -eq 0 ]; then
                echo -en "\033[0m$prefix\033[0m$header\033[0m"
                # clear out the header w/ blanks
                header="\033[${color}m$(echo -e "$header" \
                    | lib_strip_color \
                    | sed 's/./ /g' \
                    | tr -d '\n')"
            else
                echo -en "$prefix\033[0m$header"
            fi
        }
        # fill up the column with space; add an extra if we're not the very last row
        [ $single_row -eq 0 ] && msg_space=$((max_col_w - ${#msg}))
        # we're maybe last in the row, last in the list, or a regular column
        [ $is_last_val -eq 1 -a $is_last_col -eq 0 ] && {
            # add in space for the columns we're missing
            cols_missing=$((msg_per_col - (i % msg_per_col) - 1))
            msg_space=$(( msg_space + (cols_missing * max_col_w) + (cols_missing * ${#delim_raw}) ))
        }
        [ $msg_space -ge 1 ] && msg="$msg${space:0:msg_space}"
        [ $is_last_col -eq 0 -a $is_last_val -eq 0 ] && msg="$msg$delim"
        echo -en "\033[${color}m$msg"
        [ $is_last_col -eq 1 -o $is_last_val -eq 1 ] && {
            echo -e "\033[0m$suffix"
            let row+=1
        }
    done
    echo -en "\033[0m"
}
