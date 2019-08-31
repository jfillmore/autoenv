#  ,.-'`'-={[** lib.sh **]}=-'`'-.,
# .--------------------------------. 
# | breathe life into bash scripts |
# '--------------------------------'

# set our logging tag based on env var, param, or finally whoever sourced us
LIB_TAG="${LIB_TAG:-${1:-$(basename "$0")}}"


lib_log() {
    local clr="${2:-0;34;40}"
    [ "${clr//;/}" = "$clr" ] && clr=$(lib_color "$clr")
    echo -e "\033[1;30;40m# ($LIB_TAG) \033[${clr}m${1:-}\033[0;0;0m" >&2
}


lib_log_error() {
    local clr="${2:-0;31;40}"
    local error_label="${3:-error}"
    [ "${clr//;/}" = "$clr" ] && clr=$(lib_color "$clr")
    echo -e "\033[1;31;40m# ($LIB_TAG $error_label) \033[${clr}m${1:-}\033[0;0;0m" >&2
}


lib_log_raw() {
    local clr="${2:-0;37;40}"
    [ "${clr//;/}" = "$clr" ] && clr=$(lib_color "$clr")
    echo -e "\033[${clr}m${1:-}\033[0;0;0m" >&2
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
        && msg="$msg$opts_msg$opts" \
        || msg="Options$opts_msg:\033[1;34;40m$opts\033[0;0m\n$msg"
    while [ -z "$match" ]; do
        error=
        echo -en "$line_break$msg > " >&2
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

# return 0 if any args prior to -- or == are found the rest of the args; else 1
# if so and == is the pivot, the index (0-based) of the match and item matched
# are printed to stdout separated by tabs
# e.g.:
# 1) lib_in_list foo bar == at the bar && echo "saw foo or bar"
#    > 2	bar
# 2) lib_in_list foo bar -- at the food bard || echo "did not see foo or bar"
lib_in_list() {
    local wanted=()
    local to_search=()
    local echo
    local pivot=
    local i j

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
    [ ${#wanted[*]} -eq 0 -o "${#to_search[*]}" -eq 0 ] && return 1
    for ((i=0; i<${#wanted[*]}; i++)); do
        for ((j=0; j<${#to_search[*]}; j++)); do
            [ "${wanted[i]}" = "${to_search[j]}" ] &&  {
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
# $1 = bash color code (e.g. 0;31;40) or nickname
# $2 = optional text to print with the color; otherwise ethe code is printed
# $3 = optional bash color code to reset to after if text is given
lib_color() {
    local clr="$1"
    local msg="${2:-}"
    local clr_end="${3:-}"
    local colors=(
        black red green yellow blue purple cyan lightgrey reset
        darkgrey pink lime lemon lightblue fushia lightcyan white reset
    )
    local color_codes=(
        '0;30;40' '0;31;40' '0;32;40' '0;33;40' '0;34;40' '0;35;40' '0;36;40' '0;37;40' '0;0;0'
        '1;30;40' '1;31;40' '1;32;40' '1;33;40' '1;34;40' '1;35;40' '1;36;40' '1;37;40' '0;0;0'
    )
    local i
    # map names to codes if needed
    [ "${clr//;/}" = "$clr" ] && {
        i=$(lib_in_list "$clr" == "${colors[@]}" | cut -f 1)
        clr="${color_codes[${i:-8}]}"
    }
    if [ -z "$msg" ]; then
        echo "$clr"
    else
        clr="\033[${clr}m"
        [ -n "$clr_end" ] && {
            [ "${clr_end//;/}" = "$clr_end" ] && {
                i=$(lib_in_list "$clr_end" == "${colors[@]}" | cut -f 1)
                clr_end="${color_codes[${i:-8}]}"
            }
            clr_end="\033[${clr_end}m" 
        }
        echo -e "${clr}${msg}${clr_end}"
    fi
}
