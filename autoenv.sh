#!/bin/bash -u
#
# TODO:
# - exec batches of aliases from known envs
#   - serial (w/ basic bool logic) vs batch mode (supporting auto-restart), confirm w/ beep-alerts when waiting (e.g. notify function)
#   - dry-run
# - aliases requiring confirmation (e.g. aliases-confirm/ or special invoke method)


# --- main internals --
__AUTOENV_ROOT="${AUTOENV_ROOT:-$HOME}"  # stop scanning for autoenv dirs when this path is reached; 
__AUTOENV_ENVS=()  # list of active envs
__AUTOENV_VARS=()  # names of environmental variables we set; named are prefixed with the env depth they were applied at
__AUTOENV_ALIASES=()  # names of aliases we created; named are prefixed with the env depth they were applied at

__AUTOENV_SCAN_DEPTH=${AUTOENV_DEPTH:-16}  # how far up to scan at most
__AUTOENV_CMDS=(
    add
    create
    delete
    edit
    file-index
    go
    help
    info
    reload
    run
    sync
)
# trim slash, if needed
[ "${__AUTOENV_ROOT:${#__AUTOENV_ROOT}-1}" = '/' ] \
    && __AUTOENV_ROOT="${__AUTOENV_ROOT:0:${#__AUTOENV_ROOT}-1}"


# -- other key env vars --
AUTOENV=${AUTOENV:-1}
AUTOENV_DEBUG="${AUTOENV_DEBUG:-0}"
AUTOENV_ENV=
AUTOENV_PENV=


# helper library; find it either by:
# 1 - same dir as autoenv.sh script/link
# 2 - if we're a symlink, then in the actual location of this script
__AUTOENV_TAG="æ"
if [ -f "$(dirname ${BASH_SOURCE[0]})/lib.sh" ]; then
    . "$(dirname ${BASH_SOURCE[0]})/lib.sh" "$__AUTOENV_TAG" || {
        echo "Failed to source lib.sh from script dir" >&2
        return 1
    }
elif [ -f "$(dirname $(readlink ${BASH_SOURCE[0]}))/lib.sh" ]; then
    . "$(dirname $(readlink ${BASH_SOURCE[0]}))/lib.sh" "$__AUTOENV_TAG" || {
        echo "Failed to source lib.sh from symlink dir" >&2
        return 1
    }
else
    echo "Unable to find lib.sh in $(dirname ${BASH_SOURCE[0]})/ or $(dirname $(readlink ${BASH_SOURCE[0]}))" >&2
    return 1
fi



# ------------------------------------------------------------------------------
# usage info
# ------------------------------------------------------------------------------

__autoenv_usage() {
    lib_log "Augments 'cd' to manage aliases, scripts, and env vars based on nested '.autoenv' dirs" '1;37;40'
    lib_log_raw "
COMMANDS

Command and argument names (except paths) can be abbreviated so long as only
one match is found.

  # generic
  help                     this info
  info                     summarize known and active envs
  reload                   reinitialize all .envs; forgets removed envs, adds new envs

  # env management
  add PATH [NAME]          add existing env to memory for tracking
  create PATH [NAME]       create skeleton .autoenv dir and print usage hints
  edit [WHAT] [WHICH]      launch env editor, optionally for a specific thing
  forget NAME              remove this env from memory; deactivate and down

  # env operations
  go [-u|--up] ENV         CD to the environment named and optionally run it
  up [SCRIPT]              executes \`nohup run.d/* &>/dev/null </dev/null &\`, in order
  down [SCRIPT]            stop one or more processes from 'run.d/'
  file-index DIR [DIR2]    Generate index files in each dir; needed for syncs
  sync NAME [NAME2]        Fetch files/scripts based on \$AUTOENV_SYNC_URL

Autoscanning can be disabled by setting AUTOENV=0; any other value enables it.
"
}


__autoenv_usage_sync() {
    lib_log "Usage: autoenv sync SYNCNAME [SYNCNAME2]"
    lib_log_raw "

Sync files to the DIR given based on the target NAME(S). Requires you to set
\$AUTOENV_SYNC_URL to a website that contains directories matching the
SYNCNAME(S) given. Each directory must have an 'index.autoenv' file generated
by the 'file-index' autoenv command. Uses 'curl' by default but falls back to
'wget' if curl is not installed.

ARGUMENTS:

  -h|--help         This information
  -v|--verbose      Print verbose sync information
  -d|--dryrun       Do not make any changes; just report commands that would run
  SYNCNAME          Upstream name of target folder to sync locally (repeatable)

Examples:

  # generate a file index of favorite scripts or dev tools within a git repo
  [foo ~]$ cd ~/git/my-default-env/ && autoenv file-index bash python
  [foo ~/git/my-default-env]$ git add . && git commit -m 'blah blah' && git push

  # on another host, automatically initialize our bash stuff
  [bar ~]$ export AUTOENV_SYNC_URL=https://raw.githubusercontent.com/joesmith/my-default-env/master/ 
  [bar ~]$ autoenv sync bash
"
}

__autoenv_usage_scan() {
    lib_log "Usage: autoenv create [ENV_DIR] [ENV_NAME]"
    lib_log_raw "

SCAN (automatic on directory change by default)

Scans up to $__AUTOENV_SCAN_DEPTH parent directories to look for '.autoenv/'. If
found, it is 'activated' until you 'cd' out of the path (or into a nested env).

Additionally, each '.autoenv/' directory may contain:

  .autoenv/
    .name     - short, unique name of the env (e.g. /^[a-zA-Z0-9\-_]+$/);
                this env is symlinked to by AUTOENV_ROOT/.autoenv/\$name
    aliases/  - aliases to automatically define
    cd.d/     - each script is executed in a subshell on \`cd\`; best kept light\!
    exit.d/   - on exit, source each file (e.g. python venv deacivate)
    init.d/   - on init, source each file (e.g. python venv activate)
    run.d/    - scripts to run on 'autoenv up'; pid files for tracking
    scripts/  - scripts to be appended to your \$PATH
    vars/     - env vars are set for each file basd on contents

By default scans are limited to your \$HOME directory. This can be overridden
by the \$AUTOENV_ROOT environmental variable. Use with caution!

Aliases and scripts in deeper nested envs take priority over parent envs. The
deepest active venv will always have 'AUTOENV_ENV' pointing to the env
directory, but aliases will also have 'AUTOENV_PENV' set to the specific env
that is the parent of the alias definition.
"
}


__autoenv_usage_add() {
    lib_log "Usage: autoenv add [ENV_DIR] [ENV_NAME]"
    lib_log_raw "

Add tracking for the ENV_DIR (default: current directory) with the given ENV
NAME (defaults to ENV_DIR/.name or basename ENV_DIR). Assumes that .autoenv/
already exists in ENV_DIR.

Tracking is added to $__AUTOENV_ROOT/envs/ using ENV_NAME.
"
}


__autoenv_usage_create() {
    lib_log "Usage: autoenv create [ENV_DIR] [ENV_NAME]"
    lib_log_raw "

Create an env in the directory given (default: current directory) and with the
name given (default: directory base name). Links ${__AUTOENV_ROOT}/envs/\$ENV_NAME
to the ENV_DIR.

Automatically creates '.autoenv/{vars,aliases,exit.d,init.d,up.d}/' in ENV_DIR.
"
}


__autoenv_usage_forget() {
    lib_log "Usage: autoenv forget [ENV_NAME]"
    lib_log_raw "

Forget about an env (e.g. remove tracking from $__AUTOENV_ROOT/envs/). Inverse
of 'add'.
"
}


__autoenv_usage_file-index() {
    lib_log "Usage: autoenv file-index DIR [DIR2]"
    lib_log_raw "
"
}


__autoenv_usage_edit() {
    lib_log "Usage: autoenv edit [WHAT] [WHICH]"
    lib_log_raw "

Edit active (based on depth) env, optionally specifying what/which things to
edit. Allows partial matches as long as arguments are unambiguous.
"
}


# ------------------------------------------------------------------------------
# helpers
# ------------------------------------------------------------------------------


# log an internal debugging message
# $1 = log message
# $2 = optional color to use; e.g. '1;35;40'
__autoenv_debug() {
    [ ${AUTOENV_DEBUG:-0} = 1 ] || return 0
    local color="${2:-1;35;40}"
    echo -e "\033[0;35;40m# ($__AUTOENV_TAG debug) \033[${color}m${1:-}\033[0;0;0m" >&2
}


# look at each path in the envs and return 0 if found, 1 if not
# $1 = autoenv dir to check (e.g. "$HOME/code/proj_x")
__autoenv_is_active() {
    local autoenv_dir="$1"
    local i
    for ((i=0; i<${#__AUTOENV_ENVS[*]}; i++)); do
        [ "${__AUTOENV_ENVS[i]}" = "$autoenv_dir" ] && return 0
    done
    return 1
}


# replace or trim an entry in $PATH
# $1 = path to match
# $2 = optional replacement to make; prunes path otherwise
__autoenv_path_swap() {
    local tmp_path=":$PATH:"
    [ $# -eq 2 ] \
        && tmp_path="${tmp_path/:$1:/:$2:}" \
        || tmp_path="${tmp_path/:$1:/:}"
    tmp_path="${tmp_path%:}"
    tmp_path="${tmp_path#:}"
    PATH=$tmp_path
}


# insert an env's scripts dir into the PATH, ensuring child paths come before parent envs
# $1 = path to prepend
# $2 = depth of the path we're prepending, to ensure we insert before parents
__autoenv_path_prepend_scripts() {
    local new_path="$1"
    local depth="$2"
    local env_dir="${new_path%%.autoenv/scripts}"
    local parent_env
    local i
    # if we're at min depth, just append to PATH since we know we're last
    if [ $depth -eq 1 ]; then
        __autoenv_debug "appending first env ($new_path) to \$PATH"
        PATH="$PATH:$new_path"
        return 0
    fi
    # otherwise we need to figure out if any parent envs have scripts
    # if so, make sure we insert before the nearest one
    for ((i=$depth-1; i>0; i--)); do
        parent_env="${__AUTOENV_ENVS[$i-1]}"
        [ -d "$parent_env/.autoenv/scripts" ] && {
            __autoenv_debug "adding $new_path to \$PATH before '$parent_env'"
            __autoenv_path_swap \
                "$parent_env/.autoenv/scripts" \
                "$new_path:$parent_env/.autoenv/scripts"
            return 0
        }
    done
    # no parents had a scripts dir
    __autoenv_debug "appending $new_path (first child w/ scripts)"
    PATH="$PATH:$new_path"
}


# return the depth a venv was found at; 1 based index
__autoenv_get_depth() {
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


# add an env to the list of active envs, possibly at the start/middle
__autoenv_add_env() {
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


# remove an env, if found, from the list of active envs
__autoenv_rem_env() {
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
        lib_log_error "cannot remove env '$autoenv_dir'; not found in list of envs"
        return 1
    }
    [ ${#active_envs[*]} -gt 0 ] \
        && __AUTOENV_ENVS=("${active_envs[@]}") \
        || __AUTOENV_ENVS=()
    return 0
}


# find the lowest depth item based on name
# $1=item name
# $2=min scan depth
# $3+=items to scan in format '$depth:$item_name'
__autoenv_first_above() {
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


# find the highest depth item based on name
# $1=item name
# $2=max scan depth
# $3+=items to scan in format '$depth:$item_name'
__autoenv_last_below() {
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


# print the depth of the env given
__autoenv_depth() {
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


# echos curl or wget w/ default args to assist with HTTP requests
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
            lib_log "Unable to locate 'curl' or 'wget' to download files."
            return 1
        }
        agent="$agent --quiet -O -"
    fi
    echo "$agent"
}



# ------------------------------------------------------------------------------
# main logic
# ------------------------------------------------------------------------------

# create a new env and print helpful usage info
# $1 = root directory for the env (default .)
# $2 = name of the env (default=dir basename)
__autoenv_create() {
    local root_env_dir="$__AUTOENV_ROOT/.autoenv/envs"
    local env_root="${1:-.}"
    local env_name="${2:-}"

    [ -n "$env_name" ] || env_name=$(basename $(builtin cd "$env_root" && pwd -P))
    # avoid dupe names
    [ -L "$root_env_dir/envs/$env_name" ] && {
        lib_log_error "An env named '$env_name' already exists (env=$(readlink \"$root_env_dir/envs/$env_name\" 2>/dev/null))"
        return 1
    }
    # init the env
    mkdir -p "$env_root/.autoenv/{vars,aliases,exit.d,init.d,up.d}" || {
        lib_log_error "Failed to create autoenv dirs in '$env_root/.autoenv/'"
        return 1
    }
    __autoenv_add "$env_root" "$env_name" || return 1

    # let the user know about it
    lib_log "** created env '$env_name'" '1;32;40'
    lib_log "  - tracked at: '$root_env_dir/envs/$env_name'" '1;32;40'
    lib_log "** run 'autoenv edit [what] [which]' to customize" '1;32;40'
}


# add an existing .autoenv dir to $__AUTOENV_ROOT/.autoenv/envs and sets .autoenv/.name
# $1 = root directory for the env (default .)
# $2 = name of the env (default .autoenv/.name)
__autoenv_add() {
    local env_root="${1:-.}"
    local env_name="${2:-}"
    local root_env_dir="$__AUTOENV_ROOT/.autoenv/envs"

    # always ensure our root autoenv is setup
    mkdir -p "$root_env_dir" || {
        lib_log_error "Failed to create '$root_env_dir'"
        return 1
    }
    # normalize the name and get a full path
    env_root=$(builtin cd "$env_root" && pwd -P)
    # no name given? try to infer it
    [ -n "$env_name" ] || {
        [ -s "$env_root/.autoenv/.name" ] \
            && env_name=$(<$env_root/.autoenv/.name)\
            || env_name=$(basename "$env_root")
    }
    [ -d "$env_root/.autoenv" ] || {
        lib_log_error "No .autoenv/ dir found in '$env_root' to add"
        return 1
    }
    [ -L "$root_env_dir/envs/$env_name" ] && {
        lib_log_error "An env named '$env_name' already exists (env=$(readlink \"$root_env_dir/envs/$env_name\" 2>/dev/null))"
        return 1
    }
    echo "$env_name" > "$env_root/.autoenv/.name" || {
        lib_log_error "Failed to set '$env_root' name to '$env_name'"
        return 1
    }
    ln -s "$env_root" "$root_env_dir/$env_name" || {
        lib_log_error "Failed to link '$env_root' > '$root_env_dir/$env_name' to add env '$env_name'"
        return 1
    }
}


# remove autoenv tracking
__autoenv_forget() {
    local env_name="$1"
    local env_root
    local root_env_dir="$__AUTOENV_ROOT/.autoenv/envs"
    [ -d "$root_env_dir/$env_name" ] || {
        lib_log_error "No env known by name '$env_name'"
        return 1
    }
    env_root=$(readlink "$root_env_dir/$env_name")
    rm "$root_env_dir/$env_name" || {
        lib_log_error "Failed remove link '$root_env_dir/$env_name'"
        return 1
    }
    # deactivate and down it
    lib_in_list "$env_root" -- "${__AUTOENV_ENVS[@]}" && {
        __autoenv_down "$env_root"
        __autoenv_exit "$env_root"
    }
    return 0
}


# edit aspects of an environment in #EDITOR; always assumes current environment
__autoenv_edit() {
    local add_exec=0
    local choice
    local choices
    local do_reload=0
    local env_opts=(
        '(a)lias'
        '(e)xit script'
        '(i)nit script'
        '(r)un script'
        '(s)cript'
        '(v)ar'
    )
    local find_args=(-maxdepth 1 -type f)
    local item_type
    local needs_exec=0
    local new
    local origIFS="$IFS"
    local path
    local retval

    [ -z "$VISUAL" ] && {
        echo "Please set VISUAL to use the 'edit' command." >&2
        return 1
    }

    # determine what type of thing to edit
    [ $# -eq 0 ] && {
        lib_log "=== Editing $AUTOENV_ENV ==="
        item_type="$(
            lib_prompt -f'()' -n 1 -m "Please choose what to edit" \
            "${env_opts[@]}"
        )"
    } || {
        item_type=$(lib_match_one "$1" -i '()' -- "${env_opts[@]}") \
            || {
                echo "Input '$1' failed to match at least exactly one of: ${env_opts[@]} (matched: '$item_type')" >&2
                return 1
            }
        shift
    }
    case "$item_type" in
        alias)
            path="$AUTOENV_ENV/.autoenv/aliases"
            ;;
        exit\ script)
            path="$AUTOENV_ENV/.autoenv/exit.d"
            mkdir -p "$path" &>/dev/null
            find_args+=(-perm -u+x)
            needs_exec=1
            ;;
        init\ script)
            path="$AUTOENV_ENV/.autoenv/init.d"
            mkdir -p "$path" &>/dev/null
            find_args+=(-perm -u+x)
            needs_exec=1
            ;;
        run\ script)
            path="$AUTOENV_ENV/.autoenv/run.d"
            mkdir -p "$path" &>/dev/null
            find_args+=(-perm -u+x)
            needs_exec=1
            ;;
        script)
            path="$AUTOENV_ENV/.autoenv/scripts"
            mkdir -p "$path" &>/dev/null
            find_args+=(-perm -u+x)
            needs_exec=1
            ;;
        var)
            path="$AUTOENV_ENV/.autoenv/vars"
            mkdir -p "$path" &>/dev/null
            ;;
        *)
            echo "Failed to parse item type: $item_type" >&2
            return 1
            ;;
    esac

    # figure out which item to edit
    mkdir -p "$path" &>/dev/null
    new="+ (new $item_type)"
    IFS=$'\n'
    choices=($(builtin cd "$path" && find . "${find_args[@]}" | sort | sed 's/^\.\///g'))
    choices+=("$new")
    IFS="$origIFS"
    [ $# -eq 0 ] && {
        lib_log "=== Editing $AUTOENV_ENV / $item_type ==="
        choice=$(lib_prompt -b -f -m "Which $item_type? (save an empty file to delete)" "${choices[@]}")
    } || {
        choice=$(lib_match_one "$1" -- "${choices[@]}") \
            || {
                echo "Input '$1' failed to match at least one of: ${choices[@]} (matched: '$choice')" >&1
                return 1
            }
        shift
    }
    if [ "$choice" = "$new" ]; then
        add_exec=$needs_exec
        do_reload=1
        choice=$(lib_prompt "Enter name of $item_type to create")
        [ -n "$choice" ] || {
            echo "Aborting; no $item_type name given to create" >&2
            return 1
        }
    fi

    # finally, edit the item in question
    $VISUAL "$path/$choice"
    retval=$?
    [ $retval -eq 0 ] && {
        # look for post-edit adjustments (e.g. delete empty stuff, add exec perms)
        if [ \! -s "$path/$choice" ]; then
            rm -f "$path/$choice"
            lib_log "Deleting empty $item_type" >&2
        elif [ $add_exec -eq 1 ]; then
            chmod u+x "$path/$choice" || {
                echo "Failed to add executions perms to '$path/$choice'" >&2
                return 1
            }
        fi
        # if we added something new we should just assume an env reload (even though scripts/init.d/exit.d don't really need it)
        [ $do_reload -eq 1 ] && __autoenv reload
    }

    return $retval
}


# use nohup and tie-off std{in/out/err} to execute each script in a subshell
# runs '.autoenv/up.d/*' in alphabetical order
__autoenv_up() {
    # FIXME - daemons vs scripts
    local env_dir="$1"
    local up_dir="$env_dir/.autoenv/up.d"
    local script
    local pid_file

    [ -d "$up_dir" ] || return 0

    find $up_dir -maxdepth 1 \( -type f -o -type l \) \! -name .\* \
        | sort \
        | while read script; do
            pid_file="$up_dir/.$script.pid"
            [ -s "$pid_file" ] && {
                lib_log "PID file already exists for $script: $(<"$pid_file")"
                exit 1
            }
            ( 
                cd "$env_dir" || exit 1
                AUTOENV_ENV="$env_dir" nohup "$script" &>/dev/null </dev/null &
                echo $! >> "$pid_file"
                lib_log "started: $script"
                wait
                lib_log "ended: $script (retval=$?, pid=$(<"$pid_file"))"
                rm "$pid_file"
            ) &
        done
    return 0
}


# sends a sig-kill to each .pid files in autoenv/up.d 
__autoenv_down() {
    # FIXME - daemons vs scripts
    local env_dir="$1"
    local up_dir="$env_dir/.autoenv/up.d"
    local script
    local pid
    local i

    [ -d "$up_dir" ] || return 0

    find $up_dir -maxdepth 1 -name .\*.pid \
        | while read pid_file; do
            pid=$(<"$pid_file")
            # clean up crashed PIDs
            ps -p "$pid" &>/dev/null || {
                lib_log_error "No active PID running: $pid; clearing .pid file"
                rm "$pid_file" || lib_log_error "Failed to remove PID file: $pid_file"
                continue
            }
            __autoenv_debug "Killing $pid from $pid_file"
            kill "$pid"

            # ensure it shutsdown clean (and timely)
            while [ $i -lt 10 ]; do
                sleep 1
                ps -p "$pid" &>/dev/null || break
                let i+=1
            done
            [ $i -ge 10 ] && {
                lib_log_error "Failed to kill $pid after 10 seconds; maybe run: kill -9 $pid"
            }
        done
    return 0
}


# sync any env external resources based on $AUTOENV_SYNC_URL
# $1 = base dir to sync to
# $2..N = sync target names (e.g. for "GET $1/$2/index.autoenv")
# $AUTOENV_SYNC_URL = env var to URL containing sync dirs w/ index.autoenv files
__autoenv_sync() {
    local autoenv_dir="$1" && shift
    local sync_src="${AUTOENV_SYNC_URL:-}"
    [ -n "$sync_src" ] || {
        lib_log_error "Sync failed; Export 'AUTOENV_SYNC_URL' to a URL containing autoenv sync directories." 
        return 1
    }
    local http=$(__autoenv_http_agent) || return 1
    shasum="$(which shasum 2>/dev/null) -a 1" \
        || shasum=$(which sha1sum 2>/dev/null) \
        || {
            lib_log_error "Failed to locate 'shasum' or 'sha1sum' binary."
            return 1
        }
    # do everything in subshells to minimize env polution
    (
    local target base_dir file_name exec_bit checksum path tmp_path \
        new_checksum old_checksum preview_lines file_changed
    cd "$autoenv_dir" || {
        lib_log "Failed to change to sync directory '$HOME'."
        exit 1
    }
    # for each target download the autoenv index and listed files
    while [ $# -gt 0 ]; do
        target="$1" && shift
        __autoenv_debug "Downloading index list for '$target'"
        # download all the files listed
        $http "$sync_src/$target/index.autoenv" | while read exec_bit checksum path; do
            __autoenv_debug "fetching file '$path'"
            # normalize the path to clean extra slashes, preceding periods
            path=$(echo $path | sed 's#//*#/#g' | sed 's#^\./##')
            base_dir=$(dirname "$path") || {
                lib_log_error "Failed to get base directory of '$path'."
                exit 1
            }
            file_name=$(basename "$path") || {
                lib_log_error "Failed to get file name of '$path'."
                exit 1
            }
            tmp_path="$base_dir/.$file_name.autoenv-sync.$$"
            "$http" "$sync_src/$target/$path" > "$tmp_path" \
                || {
                    rm "$tmp_path" &>/dev/null
                    lib_log_error "Failed to download '$sync_src/$target/$path' to '$tmp_path'."
                    exit 1
                }
            # does the checksum match?
            new_checksum=$($shasum "$tmp_path" | awk '{print $1}') \
                || {
                    lib_log_error "Failed to generate checksum for '$path'."
                    exit 1
                }
            if [ "$new_checksum" != "$checksum" ]; then
                preview_lines=6
                __autoenv_debug "-- File checksum mismatch (first $preview_lines lines)"
                __autoenv_debug "------------------------------------------"
                head -n $preview_lines "$tmp_path" | __autoenv_debug
                __autoenv_debug "------------------------------------------"
                # file failed to download... odd. Permissions/misconfig, perhaps?
                {
                    rm "$tmp_path" &>/dev/null
                    lib_log_error "Checksum error on '$path' from '$target' (expected: $checksum, got: $new_checksum)."
                    exit 1
                }
            fi
            # do we have this file already, and with a matching checksum?
            file_changed=1
            if [ -e "$base_dir/$file_name" ]; then
                old_checksum=$($shasum "$base_dir/$file_name" | awk '{print $1}') \
                    || {
                        rm "$tmp_path" &>/dev/null
                        lib_log_error "Failed to generate checksum for existing copy of '$path'."
                        exit 1
                    }
                if [ "$old_checksum" = "$checksum" ]; then
                    __autoenv_debug "-- skipping unchanged file"
                    file_changed=0
                fi
                # regardless if the file changed make sure the exec bit is set right
                if [ $file_changed -eq 0 \
                    -a $exec_bit = '1' \
                    -a ! -x "$base_dir/$file_name" \
                    ]; then
                    __autoenv_debug "-- toggling execution bit"
                    chmod u+x "$base_dir/$file_name" \
                        || {
                            rm "$tmp_path" &>/dev/null
                            lib_log_error "Failed to chmod 'u+x' file '$base_dir/$file_name'."
                            exit 1
                        }
                fi
            fi
            if [ $file_changed -eq 1 ]; then
                # was this a script?
                if [ $exec_bit = '1' ]; then
                    __autoenv_debug "-- toggling execution bit"
                    chmod u+x "$tmp_path" \
                        || {
                            rm "$tmp_path" &>/dev/null
                            lib_log_error "Failed to chmod 'u+x' file '$tmp_path'."
                            exit 1
                        }
                fi
                # create any leading directories if needed
                if [ "$base_dir" != '.' ]; then
                    mkdir -p "$base_dir" \
                        || {
                            rm "$tmp_path" &>/dev/null
                            lib_log_error "Failed to create base directory '$base_dir'."
                            exit 1
                        }
                fi
                # and move it into place
                mv "$tmp_path" "$base_dir/$file_name" || {
                    rm "$tmp_path" &>/dev/null
                    lib_log_error "Failed to move '$tmp_path' to '$base_dir/$file_name'."
                    exit 1
                }
            fi
        done
    done
    )
}


# generate 'index.auto_env' for each dir given
__autoenv_file_index() {
    local dir shasum
    shasum="$(which shasum 2>/dev/null) -a 1" \
        || shasum=$(which sha1sum 2>/dev/null) \
        || {
            lib_log_error "Failed to locate 'shasum' or 'sha1sum' binary."
            return 1
        }
    while [ $# -gt 0 ]; do
        dir="$1" && shift
        __autoenv_debug "Generating index '$(basename $dir)/index.auto_env'"
        (
            local scripts name exec_bit lines checksum path
            [ -d "$dir" ] || {
                lib_log_error "Directory '$dir' does not exist"
                exit 1
            }
            builtin cd "$dir" || {
                lib_log_error "Failed to change to '$dir'."
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
                lib_log_error "Failed to generate checksum list for directory '$dir'."
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
                lib_log_error "Failed to generate index file for '$dir'."
                exit 1
            fi
            # put our new files in place
            rm .index.autoenv.$$ &>/dev/null
            mv .index.autoenv.$$.done index.autoenv || {
                rm .index.autoenv.$$.done &>/dev/null
                lib_log_error "Failed to move autoenv index '$dir/index.autoenv'."
                exit 1
            }
            lines=$(wc -l index.autoenv | awk '{print $1}')
            lib_log "index-sync '$dir' done (files: $lines, scripts: $scripts)"
        )
    done
}


# print information about the current env (name, root, aliases, vars, etc)
# $1 = which env, based on depth (e.g. 0 is first)
lib_log_env_info() {
    local depth="$1"
    local i item
    local items
    local env_dir="${__AUTOENV_ENVS[depth]}"
    
    lib_log "$(($depth + 1)). ** $(lib_color lightcyan "$(<"$env_dir/.autoenv/.name")" cyan) ** $(lib_color white "$env_dir" white)" '0;36;40'

    items=()
    for ((i=0; i<${#__AUTOENV_VARS[*]}; i++)); do
        item="${__AUTOENV_VARS[i]}"
        [ "${item%%:*}" = "$depth" ] && items[${#items[*]}]="${item##*:}"
    done
    [ ${#items[*]} -gt 0 ] && lib_log "  * ENV VARS: $(lib_color lime "${items[*]}")" '0;32;40'

    items=()
    for ((i=0; i<${#__AUTOENV_ALIASES[*]}; i++)); do
        item="${__AUTOENV_ALIASES[i]}"
        [ "${item%%:*}" = "$depth" ] && items[${#items[*]}]="${item##*:}"
    done
    [ ${#items[*]} -gt 0 ] && lib_log "  * ALIASES: $(lib_color lemon "${items[*]}")" '0;33;40'

    (
        [ -d "$env_dir/.autoenv/scripts/" ] && {
            items=()
            for item in "$env_dir/.autoenv/scripts/"*; do
                # ignore non-scripts and potential unmatched wildcard
                [ -x "$item" ] && {
                    items[${#items[*]}]="$(basename "$item")"
                }
            done
            [ ${#items[*]} -gt 0 ] && lib_log "  * SCRIPTS: $(lib_color pink "${items[*]}")" '0;31;40'
        }
    )
}


# CD to a tracked env based on name; optionally also 'up' the env
__autoenv_go() {
    local up=0
    local env_name=
    local root_envs="$__AUTOENV_ROOT/.autoenv/envs"

    while [ $# -gt 0 ]; do
        case "$1" in
            -u|--up)
                up=1
                ;;
            *)
                [ -n "$env_name" ] && {
                    lib_log_error "env name '$env_name' already given; invalid arg: $1"
                    return 1
                }
                env_name=$(lib_match_one -s "$1" -- $(ls -1 "$root_envs"))
                [ -L "$root_envs/$env_name" ] || {
                    lib_log_error "unknown env: did you mean one of these? $env_name"
                    return 1
                }
                ;;
        esac
        shift
    done
    cd $(readlink "$root_envs/$env_name") || {
        lib_log_error "Failed to \"cd '$env_name'\""
        return 1
    }
    [ $up -eq 1 ] && {
        __autoenv_up || return 1
    }
    return 0
}


__autoenv_env_info() {
    local env_dir i
    [ "${#__AUTOENV_ENVS[*]}" -eq 0 ] && {
        lib_log '++ no active envs'
        return 0
    }
    # print each active env info
    lib_log "[ ENVS: $(lib_color lightcyan "$(ls -1 "$__AUTOENV_ROOT/.autoenv/envs" | tr "\n" " ")")]" '4;36;40'
    for ((i=0; i<${#__AUTOENV_ENVS[*]}; i++)); do
        env_dir="${__AUTOENV_ENVS[i]}"
        lib_log_env_info $i
    done
}


__autoenv_init() {
    local env_dir="$1"
    local name value depth item

    __autoenv_is_active "$env_dir" && return 0
    __autoenv_add_env "$env_dir"
    depth=$(__autoenv_get_depth "$env_dir") || {
        lib_log_error "Failed to get env depth for '$env_dir'"
        return 1
    }
    # we may init out-of-order to use our own env for init
    export AUTOENV_ENV="$env_dir"

    # first look at the vars to initialize those ENV variables
    [ -d "$env_dir/.autoenv/vars" ] && {
        for name in $(ls -1 "$env_dir/.autoenv/vars/"); do
            __AUTOENV_VARS[${#__AUTOENV_VARS[*]}]="$depth:$name"
            # does a nested env have this same var defined?
            item="$(__autoenv_first_above "$name" "$depth" "${__AUTOENV_VARS[@]}")"
            [ -z "$item" ] \
                && export "$name"="$(<"$env_dir/.autoenv/vars/$name")"
        done
    }

    # aliases
    [ -d "$env_dir/.autoenv/aliases" ] && {
        for name in $(ls -1 "$env_dir/.autoenv/aliases/"); do
            __AUTOENV_ALIASES[${#__AUTOENV_ALIASES[*]}]="$depth:$name"
            # does a nested env have this same alias defined?
            item="$(__autoenv_first_above "$name" "$depth" "${__AUTOENV_ALIASES[@]}")"
            [ -z "$item" ] && alias "$name"="AUTOENV_PENV='$env_dir' $(<"$env_dir/.autoenv/aliases/$name")"
        done
    }

    # scripts
    [ -d "$env_dir/.autoenv/scripts" ] && {
        # if we're more than on level deep we need to be before our parent
        # ... that is, the first parent with custom scripts
        __autoenv_path_prepend_scripts "$env_dir/.autoenv/scripts" $depth
    }

    # report our env as setup prior to running init scripts
    lib_log_env_info $(($depth - 1))

    # and finally, our init scripts
    [ -d "$env_dir/.autoenv/init.d" ] && {
        for name in $(ls -1 "$env_dir/.autoenv/init.d/"); do
            lib_log "  $ . init.d/$name" '1;35;40'
            # many scripts use sloppy var handline, so ignore this
            set +u
            source "$env_dir/.autoenv/init.d/$name" \
                || lib_log_error "Failed to run env init script '$name'"
            set -u
        done
        unset AUTOENV_ENV
    }

    # we may have init'd out-of-order, so always point to the last env
    AUTOENV_ENV="${__AUTOENV_ENVS[@]: -1}"
    
    return 0
}


__autoenv_exit() {
    local env_dir="$1"
    local kept_aliases=() kept_vars=()
    local item name depth top_item env_dir

    __autoenv_is_active "$env_dir" || return 0
    depth=$(__autoenv_depth "$env_dir")
    lib_log "$depth. -- $(lib_color pink $(<"$env_dir/.autoenv/.name") red) -- $(lib_color darkgrey "$env_dir")" '0;31;40'
    AUTOENV_ENV="$env_dir"

    # run exit scripts
    [ -d "$env_dir/.autoenv/exit.d" ] && {
        for name in $(ls -1 "$env_dir/.autoenv/exit.d/"); do
            lib_log "  $ . exit.d/$name" '0;35;40'
            source "$env_dir/.autoenv/exit.d/$name"
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

    # cleanup PATH
    [ -d "$env_dir/.autoenv/scripts" ] && {
        __autoenv_path_swap "$env_dir/.autoenv/scripts"
    }

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

    # stop tracking this env, and set our global to the top-most env, if any
    __autoenv_rem_env "$env_dir"
    [ ${#__AUTOENV_ENVS[*]} -eq 0 ] \
        && unset AUTOENV_ENV \
        || AUTOENV_ENV="${__AUTOENV_ENVS[@]: -1}"
    return 0
}


# search for autoenv dirs within this path: we may add and/or remove multiple envs
__autoenv_scan() {
    local depth=0
    local env i
    local env_name
    local found_envs=()
    local real_scan_dir
    local root_env_dir="$__AUTOENV_ROOT/.autoenv/envs"
    local scan_dir="$PWD" 
    local seen_root=0


    # warn about bad autoenv root
    [ -n "$__AUTOENV_ROOT" -a -d "$__AUTOENV_ROOT" ] || {
        lib_log "warning - AUTOENV_ROOT not set or home directory does not exist; this is required" '0;31;40'
        return 1
    }

    # get a list of all envs in our path that are tracked
    while [ $seen_root -eq 0 -a $depth -lt $__AUTOENV_SCAN_DEPTH ]; do
        # are we in or above the root?
        [ "$scan_dir" = "$__AUTOENV_ROOT" -o "${__AUTOENV_ROOT##$scan_dir}" != "$__AUTOENV_ROOT" ] \
            && seen_root=1
        [ -d "$scan_dir/.autoenv" ] && {
            # only add envs that are tracked properly
            (
                # ensure we have a name and thus have been "added" already
                [ -s "$scan_dir/.autoenv/.name" ] || {
                    lib_log "Untracked env: ${scan_dir##$__AUTOENV_ROOT/}; add with: ae add \"$scan_dir\" [NAME]" '1;33;40'
                    exit 1
                }
                env_name=$(<"$scan_dir/.autoenv/.name") || {
                    lib_log_error "Failed to read .name from '$scan_dir' env"
                    exit 1
                }
                # ensure the symlink is valid too
                real_scan_dir=$(builtin cd "$scan_dir" && pwd -P)
                [ "$(readlink "$root_env_dir/$env_name")" = $(builtin cd "$real_scan_dir" && pwd -P) ] || {
                    lib_log_error "Name mistmach: $root_env_dir/$env_name points elsewhere; fix .autoenv/.name or run: ae forget '$env_name'"
                    exit 1
                }
            ) && found_envs+=("$(builtin cd "$scan_dir" && pwd -P)")
        }
        depth=$((depth+1))
        scan_dir="$(builtin cd "$scan_dir/.." && pwd)"
    done
    [ ${#found_envs[*]} -gt 0 ] && __autoenv_debug "found envs: ${found_envs[*]}"

    # first check to see which envs no longer exist or were exited
    # ignores any envs not yet added to __AUTOENV_ROOT/.autoenv/envs
    for ((i=${#__AUTOENV_ENVS[*]}-1; i>=0; i--)); do
        env="${__AUTOENV_ENVS[i]}"
        if [ ${#found_envs[*]} -eq 0 ]; then
            __autoenv_exit "$env"
        else
            lib_in_list "$env" -- "${found_envs[@]}" \
                || __autoenv_exit "$env"
        fi
    done

    # now see which new envs were found; we *can* go in any order but it makes more sense to go in reverse for numbering
    for ((i=${#found_envs[*]}-1; i>=0; i--)); do
        env="${found_envs[i]}"
        if [ ${#__AUTOENV_ENVS[*]} -eq 0 ]; then
            __autoenv_init "$env"
        else
            lib_in_list "$env" -- "${__AUTOENV_ENVS[@]}" \
                || __autoenv_init "$env"
        fi
    done
}


# $1 = command
# $2+ = command args, if any
__autoenv() {
    local cmd retval i
    [ $# -eq 0 ] && {
        __autoenv_usage
        return 2
    }
    cmd=$(lib_match_one "$1" -- "${__AUTOENV_CMDS[@]}")
    retval=$?
    # if retval was 1 its a mismatch, so fail out
    [ $retval -ge 1 ] && {
        __autoenv_usage
        [ $retval -eq 1 ] \
            && lib_log_error "ERROR: No autoenv commands matched '$1'"
        [ $retval -gt 1 ] \
            && lib_log_error "ERROR: Multiple autoenv commands matched '$1': $cmd"
        return $retval
    }
    shift
    case "$cmd" in
        add)
            [ $# -ge 1 ] || {
                lib_log_error "usage: add PATH [NAME]"
                return 1
            }
            __autoenv_add "$@" || {
                lib_log_error "failed to add env $@"
                return 1
            }
            __autoenv_scan
            ;;
        create)
            lib_in_list "-h" "--help" -- "$@" && {
                __autoenv_usage_help
                return
            }
            __autoenv_create "$@" || {
                lib_log_error "failed to create env $@"
                return 1
            }
            __autoenv_scan
            ;;
        forget)
            [ $# -eq 1 ] || {
                lib_log_error "usage: forget NAME"
                return 1
            }
            __autoenv_forget "$1" || {
                lib_log_error "failed to forget env $1"
                return 1
            }
            ;;
        edit)
            __autoenv_edit "$@" || return 1
            ;;
        go)
            [ $# -eq 1 ] || {
                lib_log_error "usage: go [-u|--up] NAME"
                lib_log_raw "ENVS: $(lib_color lightcyan "$(ls -1 "$__AUTOENV_ROOT/.autoenv/envs" | tr "\n" " ")")" cyan
                return 1
            }
            __autoenv_go "$@" || return 1
            ;;
        help)
            __autoenv_usage
            ;;
        sync)
            [ $# -ge 1 ] || {
                lib_log_error "At least one sync name expected"
                __autoenv_usage_sync
                return 1
            }
            lib_in_list "-h" "--help" -- "$@" && {
                __autoenv_usage_sync
                return
            }
            [ ${#__AUTOENV_ENVS[*]} -gt 0 ] || {
                lib_log_error "Cannot perform sync without an active env"
                __autoenv_usage_sync
                return 1
            }
            __autoenv_sync "${__AUTOENV_ENVS[${#__AUTOENV_ENVS[*]}-1]}" "$@"
            ;;
        scan)
            lib_in_list "-h" "--help" -- "$@" && {
                __autoenv_usage_scan
                return
            }
            [ $# -ge 1 ] || {
                lib_log_error "No args expected"
                __autoenv_usage_scan
                return 1
            }
            __autoenv_scan
            ;;
        reload)
            # pop off one env at a time, starting at the end
            for ((i=${#__AUTOENV_ENVS[*]}-1; i>=0; i--)); do
                local last_env="${__AUTOENV_ENVS[i]}"
                __autoenv_exit "$last_env"
            done
            # and initialize any found in the current dir (possibly less than we had before)
            __autoenv_scan
            ;;
        go)
            [ $# -eq 1 ] || {
                lib_log_error "usage: go [-u|--up] NAME"
                return 1
            }
            __autoenv_go "$@" || return 1
            ;;
        up)
            [ ${AUTOENV:-1} -ne 0 ] && \
                __autoenv_up "${__AUTOENV_ENVS[${#__AUTOENV_ENVS[*]}-1]}" "$@"
            ;;
        down)
            [ ${AUTOENV:-1} -ne 0 ] && \
                __autoenv_down "${__AUTOENV_ENVS[${#__AUTOENV_ENVS[*]}-1]}" "$@"
            ;;
        info)
            __autoenv_env_info
            ;;
        file-index)
            [ $# -gt 0 ] || {
                lib_log_error "file-index usage: DIR [DIR2]"
                __autoenv_usage_file-index
                return 1
            }
            __autoenv_file_index "$@"
            ;;
        *)
            __autoenv_usage
            return 1
            ;;
    esac
    return 0
}


# hooks / hacks
# ------------------------------------------------------------------------------

cd() {
    local i
    local script
    local env

    builtin cd "$@" || return $?

    # ditch out early on non-interactive shells... we never should have even been part of the env
    [ "$-" == "${-##*i}" ] && return $?

    # generic things to do on all "cd" invocations
    [ ${AUTOENV:-1} -ne 0 ] && {
        # for each enabled env, run all cd.d/ scripts in alphabetical order
        for ((i=${#__AUTOENV_ENVS[*]}-1; i>=0; i--)); do
            env="${__AUTOENV_ENVS[i]}"
            [ -d "$env/.autoenv/cd.d" ] || continue
            find "$env/.autoenv/cd.d" -maxdepth 1 \( -type f -o -type l \) -perm +111 \! -name .\* \
                | sort \
                | while read script; do
                    (
                        "$script"
                    ) || lib_log_error "Error running '$script': $?"
                done
        done
    }
        
    # scan for envs, activating only known ones
    [ "${AUTOENV:-1}" -ne 0 ] && __autoenv_scan

    return 0
}


alias autoenv=__autoenv
alias ae=__autoenv

__autoenv_scan &>/dev/null
__autoenv_env_info
