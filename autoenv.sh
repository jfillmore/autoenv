#!/bin/bash -u

# BUGS
# - sometimes reloads of the same env causes dupe aliases
# - kept alias bug and $1 = unbound?

# TODO:
# - add/remove envs from tracking; require add before use (e.g. no anonymous envs)
#   - $HOME/.autoenv is special w/ tracking?
# - exec batches of aliases from known envs
#   - serial (w/ basic bool logic) vs batch mode (supporting auto-restart), confirm w/ beep-alerts when waiting (e.g. notify function)
#   - dry-run
# - aliases requiring confirmation (e.g. aliases-confirm/ or special invoke method)
# - env inheritance via symlinks?
# - path hacks for scripts so executed things can use 'em (e.g. vim)
# - create command
# - declare daemons to run somehow (symlink, script, etc)
# - exit all?


# main vars of interest
__AUTOENV_ROOT="${AUTOENV_ROOT:-$HOME}"  # stop scanning for autoenv dirs when this path is reached
# trim slash
[ "${__AUTOENV_ROOT:${#__AUTOENV_ROOT}-1}" = '/' ] \
    && __AUTOENV_ROOT="${__AUTOENV_ROOT:0:${#__AUTOENV_ROOT}-1}"

# our internals
__AUTOENV_ENVS=()  # list of active envs
__AUTOENV_VARS=()  # names of environmental variables we set; named are prefixed with the env depth they were applied at
__AUTOENV_ALIASES=()  # names of aliases we created; named are prefixed with the env depth they were applied at
__AUTOENV_IGNORE_CD=0  # when 1 we'll not mess with 'cd' so aliases can avoid trouble
__AUTOENV_AUTOSCAN=1  # can be disabled by user

__AUTOENV_SCAN_DEPTH=${AUTOENV_DEPTH:-16}  # how far up to scan at most
# used for quick command typing and validation
__AUTOENV_CMDS=(
    add create delete do edit go help info ls reload scan
    sync sync-index toggle
)


# ------------------------------------------------------------------------------
# helpers
# ------------------------------------------------------------------------------

__autoenv_log() {
    local color="${2:-0;34;40}"
    echo -e "\033[1;30;40m# (autoenv) \033[${color}m${1:-}\033[0;0;0m" >&2
}

__autoenv_log_error() {
    local color="${2:-0;31;40}"
    local error_label="${3:-error}"
    echo -e "\033[1;31;40m# (autoenv $error_label) \033[${color}m${1:-}\033[0;0;0m" >&2
}

__autoenv_log_debug() {
    [ ${AUTOENV_DEBUG:-0} = 1 ] || return 0
    local color="${2:-1;35;40}"
    echo -e "\033[0;35;40m# (autoenv debug) \033[${color}m${1:-}\033[0;0;0m" >&2
}
__autoenv_log_short() {
    local color="${2:-0;33;40}"
    echo -e "\033[${color}m${1:-}\033[0;0;0m" >&2
}

__autoenv_match_cmds() {
    [ $# -eq 1 ] || {
        __autoenv_log "one argument expected to __autoenv_get_cmd"
        return 1
    }
    local matches=()
    local i cmd
    local input="$1"
    local input_len=${#input}
    for ((i=0; i<${#__AUTOENV_CMDS[*]}; i++)); do
        cmd="${__AUTOENV_CMDS[i]}"
        # debug: echo "matching: '$input' = '${cmd:0:input_len}'" >&2
        [ "$input" = "${cmd:0:input_len}" ] \
            && matches[${#matches[*]}]="$cmd"
    done

    echo "${matches[@]}"
    # debug: echo "matches: ${matches[@]}" >&2
    if [ ${#matches[*]} -eq 0 ]; then
        return 1
    elif [ ${#matches[*]} -eq 1 ]; then
        return 0
    else
        return ${#matches[*]}
    fi
}


__autoenv_is_active() {
    # look at each path in the envs and return 0 if found, 1 if not
    local autoenv_dir="$1"
    local i
    for ((i=0; i<${#__AUTOENV_ENVS[*]}; i++)); do
        [ "${__AUTOENV_ENVS[i]}" = "$autoenv_dir" ] && return 0
    done
    return 1
}


__autoenv_is_listed() {
    # return 0 if $1 is found in later in $@, otherwise 1
    local wanted="$1"
    shift
    while [ $# -gt 0 ]; do
        [ "$wanted" = "$1" ] && return 0
        shift
    done
    return 1
}


__autoenv_get_depth() {
    # return the depth a venv was found at; 1 based index
    local autoenv_dir="$1"
    local i
    for ((i=0; i<${#__AUTOENV_ENVS[*]}; i++)); do
        [ "${__AUTOENV_ENVS[i]}" = "$autoenv_dir" ] && {
            echo $((i+1))
            return 0
        }
    done
    return 1
}


__autoenv_add_env() {
    # add an env to the list of active envs, possibly at the start/middle
    local autoenv_dir="$1"
    local env
    local i
    local active_envs=()
    # iterate over each env (if any) and figure out where we belong based on depth
    for ((i=0; i<${#__AUTOENV_ENVS[*]}; i++)); do
        env="${__AUTOENV_ENVS[i]}"
        # if its a subset then it goes in front
        [ "${env##$autoenv_dir}" != "$env" ] && break
        # otherwise after, so keep iterating
        active_envs[${#active_envs[*]}]="$env"
    done
    # now add it to the end of the list (so far)
    active_envs[${#active_envs[*]}]="$autoenv_dir"
    # add in the rest of the envs we may have had
    for ((i=i+1; i<${#__AUTOENV_ENVS[*]}; i++)); do
        active_envs[${#active_envs[*]}]="${__AUTOENV_ENVS[j]}"
    done
    __AUTOENV_ENVS=("${active_envs[@]}")
    return 0
}


__autoenv_rem_env() {
    # remove an env, if found, from the list of active envs
    local autoenv_dir="$1"
    local env i
    local active_envs=()
    local found_env=0
    for ((i=0; i<${#__AUTOENV_ENVS[*]}; i++)); do
        env="${__AUTOENV_ENVS[i]}"
        [ "$env" == "$autoenv_dir" ] \
            && found_env=1 \
            || active_envs[${#active_envs[*]}]="$env"
    done
    [ $found_env -eq 1 ] || {
        __autoenv_log_error "cannot remove env '$autoenv_dir'; not found in list of envs"
        return 1
    }
    [ ${#active_envs[*]} -gt 0 ] \
        && __AUTOENV_ENVS=("${active_envs[@]}") \
        || __AUTOENV_ENVS=()
    return 0
}


__autoenv_first_above() {
    # find the lowest depth item based on name
    # $1=item name
    # $2=min scan depth
    # $3+=items to scan in format '$depth:$item_name'
    local item="$1" min_depth="$2"
    local bottom_item bottom_depth=0
    shift
    shift
    while [ $# -gt 0 -a $min_depth -lt 1 ]; do
        # same name and above the min depth?
        if [ "${1##*:}" = "$item" -a ${1%%:*} -lt $min_depth ]; then
            # and a lower depth than what we've seen aleady?
            [ ${1%%:*} -lt $bottom_depth ] && {
                bottom_depth=${1%%:*}
                bottom_item="${1##*:}"
            }
        fi
        shift
    done
    [ $bottom_depth -gt 0 ] && echo "$bottom_depth:$bottom_item" || echo ""
}


__autoenv_last_below() {
    # find the highest depth item based on name
    # $1=item name
    # $2=max scan depth
    # $3+=items to scan in format '$depth:$item_name'
    local item="$1" max_depth="$2"
    local top_item top_depth=0
    shift
    shift
    while [ $# -gt 0 -a $max_depth -gt 1 ]; do
        # same name and below the max depth?
        if [ "${1##*:}" = "$item" -a ${1%%:*} -lt $max_depth ]; then
            # and a higher depth than what we've seen aleady?
            [ ${1%%:*} -gt $top_depth ] && {
                top_depth=${1%%:*}
                top_item="${1##*:}"
            }
        fi
        shift
    done
    [ $top_depth -gt 0 ] && echo "$top_depth:$top_item"
    return 0
}


__autoenv_depth() {
    # print the depth of the env given
    local env="$1"
    local i
    for ((i=0; i<${#__AUTOENV_ENVS[*]}; i++)); do
        [ "${__AUTOENV_ENVS[i]}" = "$env" ] && {
            echo $((i+1))
            return 0
        }
    done
    return 1
}


__autoenv_http_agent() {
    local agent https
    local url="$1"
    # see if we are using HTTPs or not
    if [ "$(echo "${url:0:6}" | tr '[a-z]' '[A-Z]')" = "HTTPS:" ]; then
        https=1
    else
        https=0
    fi
    # detect which HTTP agent is installed
    agent=$(which curl) &>/dev/null
    if [ $? -eq 0 ]; then
        agent="$agent --silent --fail"
    else
        # no curl? how about wget?
        agent=$(which wget) || {
            __autoenv_log "Unable to locate 'curl' or 'wget' to download files."
            return 1
        }
        agent="$agent --quiet -O -"
    fi
    echo "$agent"
}


# ------------------------------------------------------------------------------
# main logic
# ------------------------------------------------------------------------------

__autoenv_sync() {
    # $1 = base dir to sync to
    # $2..N = sync target names (e.g. for "GET $1/$2/index.autoenv")
    # $AUTOENV_SYNC_URL = env var to URL containing sync dirs w/ index.autoenv files
    local autoenv_dir="$1" && shift
    local sync_src="${AUTOENV_SYNC_URL:-}"
    [ -n "$sync_src" ] || {
        __autoenv_log_error "Export 'AUTOENV_SYNC_URL' to a URL containing autoenv sync directories." 
        return 1
    }
    local http=$(__autoenv_http_agent) || return 1
    shasum="$(which shasum 2>/dev/null) -a 1" \
        || shasum=$(which sha1sum 2>/dev/null) \
        || {
            __autoenv_log_error "Failed to locate 'shasum' or 'sha1sum' binary."
            return 1
        }
    # do everything in subshells to minimize env polution
    (
    set -x
    local target base_dir file_name exec_bit checksum path tmp_path \
        new_checksum old_checksum preview_lines file_changed
    cd "$autoenv_dir" || {
        __autoenv_log "Failed to change to sync directory '$HOME'."
        exit 1
    }
    # for each target download the autoenv index and listed files
    while [ $# -gt 0 ]; do
        target="$1" && shift
        __autoenv_log_debug "Downloading index list for '$target'"
        # download all the files listed
        $http "$sync_src/$target/index.autoenv" | while read exec_bit checksum path; do
            __autoenv_log_debug "fetching file '$path'"
            # normalize the path to clean extra slashes, preceding periods
            path=$(echo $path | sed 's#//*#/#g' | sed 's#^\./##')
            base_dir=$(dirname "$path") || {
                __autoenv_log_error "Failed to get base directory of '$path'."
                exit 1
            }
            file_name=$(basename "$path") || {
                __autoenv_log_error "Failed to get file name of '$path'."
                exit 1
            }
            tmp_path="$base_dir/.$file_name.autoenv-sync.$$"
            "$http" "$sync_src/$target/$path" > "$tmp_path" \
                || {
                    rm "$tmp_path" &>/dev/null
                    __autoenv_log_error "Failed to download '$sync_src/$target/$path' to '$tmp_path'."
                    exit 1
                }
            # does the checksum match?
            new_checksum=$($shasum "$tmp_path" | awk '{print $1}') \
                || {
                    __autoenv_log_error "Failed to generate checksum for '$path'."
                    exit 1
                }
            if [ "$new_checksum" != "$checksum" ]; then
                preview_lines=6
                __autoenv_log_debug "-- File checksum mismatch (first $preview_lines lines)"
                __autoenv_log_debug "------------------------------------------"
                head -n $preview_lines "$tmp_path" | __autoenv_log_debug
                __autoenv_log_debug "------------------------------------------"
                # file failed to download... odd. Permissions/misconfig, perhaps?
                {
                    rm "$tmp_path" &>/dev/null
                    __autoenv_log_error "Checksum error on '$path' from '$target' (expected: $checksum, got: $new_checksum)."
                    exit 1
                }
            fi
            # do we have this file already, and with a matching checksum?
            file_changed=1
            if [ -e "$base_dir/$file_name" ]; then
                old_checksum=$($shasum "$base_dir/$file_name" | awk '{print $1}') \
                    || {
                        rm "$tmp_path" &>/dev/null
                        __autoenv_log_error "Failed to generate checksum for existing copy of '$path'."
                        exit 1
                    }
                if [ "$old_checksum" = "$checksum" ]; then
                    __autoenv_log_debug "-- skipping unchanged file"
                    file_changed=0
                fi
                # regardless if the file changed make sure the exec bit is set right
                if [ $file_changed -eq 0 \
                    -a $exec_bit = '1' \
                    -a ! -x "$base_dir/$file_name" \
                    ]; then
                    __autoenv_log_debug "-- toggling execution bit"
                    chmod u+x "$base_dir/$file_name" \
                        || {
                            rm "$tmp_path" &>/dev/null
                            __autoenv_log_error "Failed to chmod 'u+x' file '$base_dir/$file_name'."
                            exit 1
                        }
                fi
            fi
            if [ $file_changed -eq 1 ]; then
                # was this a script?
                if [ $exec_bit = '1' ]; then
                    __autoenv_log_debug "-- toggling execution bit"
                    chmod u+x "$tmp_path" \
                        || {
                            rm "$tmp_path" &>/dev/null
                            __autoenv_log_error "Failed to chmod 'u+x' file '$tmp_path'."
                            exit 1
                        }
                fi
                # create any leading directories if needed
                if [ "$base_dir" != '.' ]; then
                    mkdir -p "$base_dir" \
                        || {
                            rm "$tmp_path" &>/dev/null
                            __autoenv_log_error "Failed to create base directory '$base_dir'."
                            exit 1
                        }
                fi
                # and move it into place
                mv "$tmp_path" "$base_dir/$file_name" || {
                    rm "$tmp_path" &>/dev/null
                    __autoenv_log_error "Failed to move '$tmp_path' to '$base_dir/$file_name'."
                    exit 1
                }
            fi
        done
    done
    )
}

__autoenv_sync_index() {
    # generate 'index.auto_env' for each dir given
    local dir shasum
    shasum="$(which shasum 2>/dev/null) -a 1" \
        || shasum=$(which sha1sum 2>/dev/null) \
        || {
            __autoenv_log_error "Failed to locate 'shasum' or 'sha1sum' binary."
            return 1
        }
    while [ $# -gt 0 ]; do
        dir="$1" && shift
        __autoenv_log_debug "Generating index '$(basename $dir)/index.auto_env'"
        (
            local scripts name exec_bit lines checksum path
            [ -d "$dir" ] || {
                __autoenv_log_error "Directory '$dir' does not exist"
                exit 1
            }
            cd "$dir" || {
                __autoenv_log_error "Failed to change to '$dir'."
                exit 1
            }
            # generate checksums for everything in here
            # don't overwrite the existing index until we are done
            find . -type f \
                -not -path '*/.git/*' \
                -not -name '.index.autoenv.*' \
                -not -name 'index.autoenv' \
                -not -name '.*.sw?' \
                -print0 \
                | xargs -0 $shasum > .index.autoenv.$$
            if [ $? -ne 0 ]; then
                rm .index.autoenv.$$ &>/dev/null
                __autoenv_log_error "Failed to generate checksum list for directory '$dir'."
                exit 1
            fi
            # add meta data (checksum, exec flag, etc) to the index
            scripts=0 # out of curiosity, how many were scripts?
            while read checksum path; do
                # figure out which were executable files
                name=$(find "$path" -type f \( -perm -u+x -o -perm -g+x -o -perm -o+x \))
                if [ ${#name} -ne 0 ]; then
                    exec_bit=1
                    scripts=$((scripts + 1))
                else 
                    exec_bit=0
                fi
                echo "$exec_bit  $checksum  $path"
            done < .index.autoenv.$$ > .index.autoenv.$$.done
            if [ $? -ne 0 ]; then
                rm .index.autoenv.$$ &>/dev/null
                rm .index.autoenv.$$.done &>/dev/null
                __autoenv_log_error "Failed to generate index file for '$dir'."
                exit 1
            fi
            # put our new files in place
            rm .index.autoenv.$$ &>/dev/null
            mv .index.autoenv.$$.done index.autoenv || {
                rm .index.autoenv.$$.done &>/dev/null
                __autoenv_log_error "Failed to move autoenv index '$dir/index.autoenv'."
                exit 1
            }
            lines=$(wc -l index.autoenv | awk '{print $1}')
            __autoenv_log "sync-index '$dir' done (files: $lines, scripts: $scripts)"
        )
    done
}


__autoenv_log_env_info() {
    # print vars/aliases/etc for an active env
    # $1 = which env, based on depth (e.g. 0 is first)
    local depth="$1"
    local i item
    local items
    
    items=()
    for ((i=0; i<${#__AUTOENV_VARS[*]}; i++)); do
        item="${__AUTOENV_VARS[i]}"
        [ "${item%%:*}" = "$depth" ] && items[${#items[*]}]="${item##*:}"
    done
    [ ${#items[*]} -gt 0 ] && __autoenv_log "* ENV VARS: ${items[*]}" '1;34;40'

    items=()
    for ((i=0; i<${#__AUTOENV_ALIASES[*]}; i++)); do
        item="${__AUTOENV_ALIASES[i]}"
        [ "${item%%:*}" = "$depth" ] && items[${#items[*]}]="${item##*:}"
    done
    [ ${#items[*]} -gt 0 ] && __autoenv_log "* ALIASES: ${items[*]}" '1;34;40'
}


__autoenv_envs_info() {
    local env i
    [ "${#__AUTOENV_ENVS[*]}" -eq 0 ] && {
        __autoenv_log '++ no active envs'
        return 0
    }
    # print each active env info
    for ((i=0; i<${#__AUTOENV_ENVS[*]}; i++)); do
        # TODO: if this is a named env, print that
        __autoenv_log "$((i+1)). ++ env ${__AUTOENV_ENVS[i]}"
        __autoenv_log_env_info $((i+1))
    done
}


__autoenv_alias() {
    local autoenv_dir="$1"
    local name="$2"
    local path="$autoenv_dir/.autoenv/aliases/$name"
    local lines
    shift
    shift
    # run in a subshell
    (
        __AUTOENV_IGNORE_CD=1
        if [ -x "$path" ]; then
            __autoenv_log "$ $name  # executable" '1;36;40'
            "$path" "$@"
        else
            lines=$(wc -l "$path" | awk '{print $1}')
            __autoenv_log "$ $SHELL $name  # $lines line script" '1;36;40'
            __autoenv_log_short "$(head "$path")" '0;36;40'
            [ $lines -gt 10 ] && {
                __autoenv_log_short "# --- snip ---" '1;36;40'
            }
            export AUTOENV_ENV="$autoenv_dir"
            "$SHELL" "$path" "$@"
        fi
    )
}


__autoenv_init() {
    local autoenv_dir="$1"
    local name value depth item

    __autoenv_is_active "$autoenv_dir" && return 0
    __autoenv_add_env "$autoenv_dir"
    depth=$(__autoenv_get_depth "$autoenv_dir") || {
        __autoenv_log_error "Failed to get env depth for '$autoenv_dir'"
        return 1
    }
    __autoenv_log "$depth. ++ init env $autoenv_dir"

    # first look at the vars to initialize those ENV variables
    [ -d "$autoenv_dir/.autoenv/vars" ] && {
        for name in $(ls -1 "$autoenv_dir/.autoenv/vars/"); do
            __AUTOENV_VARS[${#__AUTOENV_VARS[*]}]="$depth:$name"
            # does a nested env have this same var defined?
            item="$(__autoenv_first_above "$name" "$depth" "${__AUTOENV_VARS[@]}")"
            [ -z "$item" ] \
                && export "$name"="$(<"$autoenv_dir/.autoenv/vars/$name")"
        done
    }

    # aliases -- short command snippits
    [ -d "$autoenv_dir/.autoenv/aliases" ] && {
        for name in $(ls -1 "$autoenv_dir/.autoenv/aliases/"); do
            __AUTOENV_ALIASES[${#__AUTOENV_ALIASES[*]}]="$depth:$name"
            # does a nested env have this same alias defined?
            item="$(__autoenv_first_above "$name" "$depth" "${__AUTOENV_ALIASES[@]}")"
            [ -z "$item" ] \
                && alias "$name"="__autoenv_alias '$autoenv_dir' '$name'"
        done
    }

    # and finally, our init scripts
    [ -d "$autoenv_dir/.autoenv/init.d" ] && {
        for name in $(ls -1 "$autoenv_dir/.autoenv/init.d/"); do
            __autoenv_log "$ . init.d/$name" '0;32;40'
            set +u
            source "$autoenv_dir/.autoenv/init.d/$name" \
                || __autoenv_log_error "Failed to run env init script '$name'"
            set -u
        done
    }

    __autoenv_log_env_info $depth
    
    return 0
}


__autoenv_exit() {
    local autoenv_dir="$1"
    local kept_aliases=() kept_vars=()
    local item name depth top_item env_dir

    __autoenv_is_active "$autoenv_dir" || return 0
    depth=$(__autoenv_depth "$autoenv_dir")
    __autoenv_log "-- $depth. exit env $autoenv_dir" '1;31;40'

    # run exit scripts
    [ -d "$autoenv_dir/.autoenv/exit.d" ] && {
        for name in $(ls -1 "$autoenv_dir/.autoenv/exit.d/"); do
            __autoenv_log "$ . exit.d/$name" '0;31;40'
            . "$autoenv_dir/.autoenv/exit.d/$name"
        done
    }

    # unalias
    [ ${#__AUTOENV_ALIASES[*]} -gt 0 ] && {
        for item in "${__AUTOENV_ALIASES[@]}"; do
            if [ "${item%%:*}" = "$depth" ]; then
                name="${item##*:}"
                # if this alias is present in a lower depth keep it defined
                if [ -n "$(__autoenv_last_below "$name" "$depth" "${__AUTOENV_ALIASES[@]}")" ]; then
                    kept_aliases[${#kept_aliases[*]}]="$item"
                else
                    unalias "${item##*:}"
                fi
            else
                kept_aliases[${#kept_aliases[*]}]="$item"
            fi
        done
    }
    [ ${#kept_aliases[*]} -gt 0 ] \
        && __AUTOENV_ALIASES=("${kept_aliases[@]}") \
        || __AUTOENV_ALIASES=()

    # unset vars
    [ ${#__AUTOENV_VARS[*]} -gt 0 ] && {
        for item in "${__AUTOENV_VARS[@]}"; do
            if [ "${item%%:*}" = "$depth" ]; then
                name="${item##*:}"
                # if this env var is present in a lower depth redefine it, not unset
                top_item="$(__autoenv_last_below "$name" "$depth" "${__AUTOENV_VARS[@]}")"
                if [ -n "$top_item" ]; then
                    # look up the value from the env we found it in
                    env_dir="${__AUTOENV_ENVS[${top_item%%:*}]}"
                    # but at least be sure it still exists
                    [ -f "$env_dir/.autoenv/vars/$name" ] && {
                        export "$name"="$(<"$env_dir/.autoenv/vars/$name")"
                        kept_vars[${#kept_vars[*]}]="$item"
                    } || unset "$name"
                else
                    unset "$name"
                fi
            else
                kept_vars[${#kept_vars[*]}]="$item"
            fi
        done
    }
    [ ${#kept_vars[*]} -gt 0 ] \
        && __AUTOENV_VARS=("${kept_vars[@]}") \
        || __AUTOENV_VARS=()

    __autoenv_rem_env "$autoenv_dir"
    return 0
}


__autoenv_search() {
    # search for autoenv dirs within this path: we may add and/or remove multiple envs
    local depth=0
    local found_envs=()
    local env i
    local scan_dir="$PWD" 
    local seen_root=0
    while [ $seen_root -eq 0 -a $depth -lt $__AUTOENV_SCAN_DEPTH ]; do
        # TODO: something like ~/.autoenv.d/{name}/{root -> [symlink], init.d/, etc}
        # are we in or above the root?
        [ "$scan_dir" = "$__AUTOENV_ROOT" -o "${__AUTOENV_ROOT##$scan_dir}" != "$__AUTOENV_ROOT" ] && seen_root=1
        [ -d "$scan_dir/.autoenv" ] && {
            local real_ae_dir="$(builtin cd "$scan_dir" && pwd -P)"
            found_envs[${#found_envs[*]}]="$real_ae_dir"
        }
        depth=$((depth+1))
        scan_dir="$(builtin cd "$scan_dir/.." && pwd)"
    done
    [ ${#found_envs[*]} -gt 0 ] && __autoenv_log_debug "found envs: ${found_envs[@]}"

    # first check to see which envs no longer exist or were exited
    for ((i=${#__AUTOENV_ENVS[*]}-1; i>=0; i--)); do
        env="${__AUTOENV_ENVS[i]}"
        if [ ${#found_envs[*]} -eq 0 ]; then
            __autoenv_exit "$env"
        else
            __autoenv_is_listed "$env" "${found_envs[@]}" \
                || __autoenv_exit "$env"
        fi
    done

    # now see which new envs were found; we *can* go in any order but it makes more sense to go in reverse for numbering
    for ((i=${#found_envs[*]}-1; i>=0; i--)); do
        env="${found_envs[i]}"
        if [ ${#__AUTOENV_ENVS[*]} -eq 0 ]; then
            __autoenv_init "$env"
        else
            __autoenv_is_listed "$env" "${__AUTOENV_ENVS[@]}" \
                || __autoenv_init "$env"
        fi
    done
}


__autoenv_usage() {
    __autoenv_log " Augments 'cd' to manage aliases and env vars based on '.virtualenv' dirs" '1;37;40'
    __autoenv_log_short "

COMMANDS

Command names can be abbreviated so long as only one command matches.

    add NAME                 add this env to ~/.autoenv/ for tracking
    create [DIR] [NAME]      create skeleton .autoenv dir and print usage hints
    delete NAME              remove this env to ~/.autoenv
    do DO_ARGS               run one or more aliases from this env and/or others
    go NAME                  change directories and activate the env named
    help                     this info
    info                     summarize current env
    edit                     launch env editor
    ls                       list known autoenv envs
    reload                   reload the current env, if any
    toggle                   toggle auto-scan of new autoenv envs (currently enabled=$__AUTOENV_AUTOSCAN)
    scan                     manual scan for autoenv envs changes (e.g. while auto-scan is off)
    sync NAME [NAME2]        Fetch files/scripts based on \$AUTOENV_SYNC_URL
    sync-index [DIR] [DIR2]  Generate sync index files for upload

SCAN

Scans up to $__AUTOENV_SCAN_DEPTH parent directories to look for '.autoenv/'. If
found, it is 'activated' until you 'cd' out of the path (or into a nested env).
This dynamicaly sets/unsets the vars and aliases found in '.autoenv/'.

  .autoenv/
    exit.d/   - on exit, each file is sourced (e.g. python venv deacivate)
    vars/     - an env vars is set for each file using its contents (
    aliases/  - aliases are created for each file name to run the binary/script in a subshell
    init.d/   - on init, each file is sourced (e.g. python venv activate)

By default scans are limited to your \$HOME directory. This can be overridden
by the \$AUTOENV_ROOT environmental variable. Use with caution!

The environmental variable AUTOENV_DIR will be set during execution of aliases,
init, and exit scripts. It is set to the directory where '.autoenv' was found.

# TODO: envs must be added explicitly; otherwise this warns of presence only

DO

When envs are tracked their name can be used to run aliases from different
envs together. Any non-zero return codes will cause execution to stop.
Aliases always run in a subshell to avoid affecting the current env. Alias
names are cached on init, but the contents are ran from the file each time.

When using the 'exec' command aliases must start with a '+' to allow for args.
(e.g. '+build-all --quiet'). Aliases from any env can be referenced if prefixed
with the env's name (e.g. '+proj2/deploy-all'), allowing for cross-env combos.


For example:

    $ cd ~/code/app-build
    $ autoenv add app-build
    $ cd ~/code/app-deploy
    $ autoenv add app-deploy
    $ autoenv exec +app-build/build-all --quiet +deploy-all
" '0;33;40'
}


__autoenv() {
    local cmds retval i
    [ $# -eq 0 ] && {
        __autoenv_usage
        return 2
    }
    cmds="$(__autoenv_match_cmds "$1")" 
    retval=$?
    # if retval was 1 its a mismatch, but we'll handle that below
    [ $retval -ge 1 ] && {
        __autoenv_usage
        [ $retval -eq 1 ] \
            && echo "ERROR: No autoenv commands matched '$1'" >&2
        [ $retval -gt 1 ] \
            && echo "ERROR: Multiple autoenv commands matched '$1': $cmds" >&2
        return $retval
    }
    shift
    case "$cmds" in
        add)
            echo "TODO"
            return 1
            ;;
        create)
            echo "TODO"
            return 1
            ;;
        delete)
            echo "TODO"
            return 1
            ;;
        do)
            echo "TODO"
            return 1
            ;;
        edit)
            echo "TODO"
            return 1
            ;;
        go)
            echo "TODO"
            return 1
            ;;
        ls)
            echo "TODO"
            return 1
            ;;
        help)
            __autoenv_usage
            ;;
        toggle)
            [ $__AUTOENV_AUTOSCAN -eq 1 ] \
                && {
                    __AUTOENV_AUTOSCAN=0
                    __autoenv_log "autoenv scanning disabled"
                } \
                || {
                    __AUTOENV_AUTOSCAN=1
                    __autoenv_log "autoenv scanning enabled"
                    __autoenv_search
                }

            ;;
        scan)
            __autoenv_search
            ;;
        sync)
            [ ${#__AUTOENV_ENVS[*]} -gt 0 ] || {
                __autoenv_log_error "Cannot perform sync without an active env"
            }
            __autoenv_sync "${__AUTOENV_ENVS[${#__AUTOENV_ENVS[*]}-1]}" "$@"
            ;;
        reload)
            # pop off one env at a time, starting at the end
            for ((i=${#__AUTOENV_ENVS[*]}-1; i>=0; i--)); do
                local last_env="${__AUTOENV_ENVS[i]}"
                __autoenv_exit "$last_env"
            done
            # and initialize any found in the current dir (possibly less than we had before)
            __autoenv_search
            ;;
        info)
            __autoenv_envs_info
            ;;
        sync)
            [ $# -gt 0 ] || {
                __autoenv_log_error "sync usage: NAME [NAME2]"
                return 1
            }
            [ ${#__AUTOENV_ENVS[*]} -gt 0 ] || {
                __autoenv_log_error "Cannot perform sync without an active env"
            }
            __autoenv_sync "${__AUTOENV_ENVS[${#__AUTOENV_ENVS[*]}-1]}" "$@"
            ;;
        sync-index)
            [ $# -gt 0 ] || {
                __autoenv_log_error "sync-index usage: DIRS"
                return 1
            }
            __autoenv_sync_index "$@"
            ;;
        *)
            __autoenv_usage
            return 1
            ;;
    esac
    return 0
}


# hooks
# ------------------------------------------------------------------------------

cd() {
    builtin cd "$@" || return $?

    # ditch out early on non-interactive shells... we never should have even been part of the env
    [ "$-" == "${-##*i}" ] && return $?

    # warn about bad autoenv root
    [ -n "$__AUTOENV_ROOT" -a -d "$__AUTOENV_ROOT" ] || {
        __autoenv_log "warning - AUTOENV_ROOT not set or directory does not exist; this is required for security" '0;31;40'
    }

    # generic things to do on all "cd" invocations (TODO: something like ~/.autoenv-cd.d/?)
    [ $__AUTOENV_IGNORE_CD -eq 0 ] && {
        [ -f README.md ] && {
            local readme_lines
            readme_lines=$(wc -l README.md | awk '{print $1}')
            __autoenv_log "$ head -n 3 README.md  # $readme_lines lines" '0;33;40'
            head -n 3 README.md >&2
        }
    }
    
    # look for current envs
    [ $__AUTOENV_AUTOSCAN -eq 1 ] && __autoenv_search

    return 0
}


alias autoenv=__autoenv
# TODO: really we only want to autoscan on initial sourcing of the script
if [ $# -eq 0 ]; then
    __autoenv scan
else
    __autoenv "$@"
fi
