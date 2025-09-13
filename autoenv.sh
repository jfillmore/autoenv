 #!/bin/bash -u

# DREAM
# - 

# --- main internals --
__AUTOENV_ROOT="${AUTOENV_ROOT:-$HOME}"  # stop scanning for autoenv dirs when this path is reached;
__AUTOENV_ENVS=()  # list of active envs
__AUTOENV_VARS=()  # names of environmental variables we set; named are prefixed with the env depth they were applied at
__AUTOENV_ALIASES=()  # names of aliases we created; named are prefixed with the env depth they were applied at

__AUTOENV_TAG="æ"  # for logging during automatic actions
__AUTOENV_BASE_DIR=  # location of this script
__AUTOENV_SCAN_DEPTH=${AUTOENV_DEPTH:-16}  # how far up to scan at most
__AUTOENV_CMDS=(
    add
    create
    down
    edit
    favs
    forget
    file-index
    go
    help
    info
    reload
    run
    sync
    up
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
if [ -f "$(dirname ${BASH_SOURCE[0]})/lib.sh" ]; then
    __AUTOENV_BASE_DIR="$(dirname ${BASH_SOURCE[0]})"
elif [ -f "$(dirname $(readlink ${BASH_SOURCE[0]}))/lib.sh" ]; then
    __AUTOENV_BASE_DIR="$(dirname $(readlink ${BASH_SOURCE[0]}))"
else
    echo "Unable to find lib.sh in $(dirname ${BASH_SOURCE[0]})/ or $(dirname $(readlink ${BASH_SOURCE[0]}))" >&2
    return 1
fi
. "$__AUTOENV_BASE_DIR/lib.sh" "$__AUTOENV_TAG" || {
    echo "Failed to source lib.sh from script dir" >&2
    return 1
}



# ------------------------------------------------------------------------------
# usage info
# ------------------------------------------------------------------------------

__autoenv_usage() {
    # far too slow to generate this all via lib_color/etc
    cat << EOI >&2
[0;34;40m╓══════════════════════════════════════════════════════════════════════╖[0m
[0;34;40m║[1;34;40m autoenv (æ) augments "cd" to manage aliases, scripts, and env vars   [0;34;40m║[0m
[0;34;40m║[1;34;40m via nested ".autoenv" dirs; provides tons of 'lib_\$func' helpers     [0;34;40m║[0m
[0;34;40m╟──────────────────────────────────────────────────────────────────────╢[0m
[0;34;40m║[1;37;40m usage: ae CMD [ARGS]                                                 [0;34;40m║[0m
[0;34;40m║                                                                      ║[0m
[0;34;40m║ [4;36;40mCOMMANDS                                                            [0;34;40m ║[0m
[0;34;40m║[1;36;40m Command and argument names (except paths) can be abbreviated so      [0;34;40m║[0m
[0;34;40m║[1;36;40m long as only one match is found. Every command has a -h|--help arg.  [0;34;40m║[0m
[0;34;40m║                                                                      ║[0m
[0;34;40m║[0;33;40m   # generic                                                          [0;34;40m║[0m
[0;34;40m║[1;33;40m   help[0;37;40m                     this info                                 [0;34;40m║[0m[0m
[0;34;40m║[1;33;40m   info[0;37;40m                     summarize known and active envs           [0;34;40m║[0m[0m
[0;34;40m║[1;33;40m   favs[0;37;40m [-e|--edit] [NAME]  run/edit a favorite command               [0;34;40m║[0m[0m
[0;34;40m║[1;33;40m   reload[0;37;40m                   reinitialize all .envs along the path     [0;34;40m║[0m[0m
[0;34;40m║[0;33;40m   # env management (\$HOME/.autoenv/envs/* = NAME symlinks to envs)   [0;34;40m║[0m
[0;34;40m║[1;33;40m   add[1;37;40m PATH [NAME]          [0;37;40madd existing env                          [0;34;40m║[0m
[0;34;40m║[1;33;40m   create[1;37;40m PATH [NAME]       [0;37;40mcreate .autoenv dirs; print usage hints   [0;34;40m║[0m
[0;34;40m║[1;33;40m   edit[1;37;40m [WHAT] [WHICH]      [0;37;40minteractive  env editor                   [0;34;40m║[0m
[0;34;40m║[1;33;40m   forget[1;37;40m NAME              [0;37;40mremove this env; deactivate and down      [0;34;40m║[0m
[0;34;40m║[0;33;40m   # env operations                                                   [0;34;40m║[0m
[0;34;40m║[1;33;40m   go[1;37;40m [-u|--up] NAME        [0;37;40mCD to named env dir; optionally "run" it  [0;34;40m║[0m
[0;34;40m║[1;33;40m   up[1;37;40m [DAEMON]              [0;37;40mdaemonize "up.d/" in alphabetic order     [0;34;40m║[0m
[0;34;40m║[1;33;40m   down[1;37;40m [DAEMON]            [0;37;40mstop amy started daemons from "up"        [0;34;40m║[0m
[0;34;40m║[1;33;40m   run[1;37;40m [SCRIPT]             [0;37;40mrun "run.d/" in alphabetic order          [0;34;40m║[0m
[0;34;40m║[0;33;40m   # env syncronization                                               [0;34;40m║[0m
[0;34;40m║[1;33;40m   file-index[1;37;40m DIR [DIR2]    [0;37;40mGenerate "autoenv.index" needed for syncs [0;34;40m║[0m
[0;34;40m║[1;33;40m   sync[1;37;40m NAME [NAME2]        [0;37;40mFetch files based on \$AUTOENV_SYNC_URL    [0;34;40m║[0m
[0;34;40m║                                                                      ║[0m
[0;34;40m║ [4;36;40mAUTOENV ENVIRON VARS                                                [0;34;40m ║[0m
[0;34;40m║[0;32;40m   # change run-time behavior                                         [0;34;40m║[0m[0m
[0;34;40m║[1;32;40m   AUTOENV[0;37;40m                 disables env scanning when set to 0        [0;34;40m║[0m[0m
[0;34;40m║[1;32;40m   AUTOENV_ROOT[0;37;40m            top-most possible env dir; default: \$HOME  [0;34;40m║[0m[0m
[0;34;40m║[1;32;40m   AUTOENV_DEBUG[0;37;40m           set to 1 for verbose debugging info        [0;34;40m║[0m[0m
[0;34;40m║[0;32;40m   # autotically managed by autoenv                                   [0;34;40m║[0m[0m
[0;34;40m║[1;32;40m   AUTOENV_ENV[0;37;40m             auto set to deepest active env dir         [0;34;40m║[0m[0m
[0;34;40m║[1;32;40m   AUTOENV_PENV[0;37;40m            auto set to parent env dir on alias defs   [0;34;40m║[0m[0m
[0;34;40m║                                                                      ║[0m
[0;34;40m║ [4;36;40mAUTOENV DIR STRUCTURE                                               [0;34;40m ║[0m
[0;34;40m║[0;35;40m   # env label and automated shell injections                         [0;34;40m║[0m[0m
[0;34;40m║[1;35;40m   .name[0;37;40m                   short unique env name: /^[a-zA-Z0-9\-_]+$/ [0;34;40m║[0m[0m
[0;34;40m║[1;35;40m   aliases/[0;37;40m                auto aliases based on file names/data      [0;34;40m║[0m[0m
[0;34;40m║[1;35;40m   vars/[0;37;40m                   auto environ vars based on file names/data [0;34;40m║[0m[0m
[0;34;40m║[1;35;40m   scripts/[0;37;40m                auto added to \$PATH based on env depth     [0;34;40m║[0m[0m
[0;34;40m║[0;35;40m   # automatc actions based on events (activate, up/down, run)        [0;34;40m║[0m[0m
[0;34;40m║[1;35;40m   cd.d/[0;37;40m                   run each script in a subshell on 'cd'      [0;34;40m║[0m[0m
[0;34;40m║[1;35;40m   init.d/[0;37;40m                 sources each file on first entry of env    [0;34;40m║[0m[0m
[0;34;40m║[1;35;40m   exit.d/[0;37;40m                 sources each file on exit from the env dir [0;34;40m║[0m[0m
[0;34;40m║[1;35;40m   up.d/[0;37;40m                   daemons to run on "go -u env" or "ae up"   [0;34;40m║[0m[0m
[0;34;40m║[1;35;40m   run.d/[0;37;40m                  short scripts/bins to run on "run"         [0;34;40m║[0m[0m
[0;34;40m╙══════════════════════════════════════════════════════════════════════╜[0m
EOI
}


__autoenv_usage_sync() {
    lib_log "Usage: autoenv sync [ARGUMENTS] SYNCNAME [SYNCNAME2]"
    lib_log_raw "
Sync files to the DIR given based on the target NAME(S). Requires you to set
\$AUTOENV_SYNC_URL to a website that contains directories matching the
SYNCNAME(S) given. Each directory must have an 'index.autoenv' file generated
by the 'file-index' autoenv command. Uses 'curl' by default but falls back to
'wget' if curl is not installed.

ARGUMENTS:

  -f|--force        Force download files regardless of shasums
  -h|--help         This information
  -d|--dryrun       Download and check files, but don't replace existing ones
  -v|--verbose      Print verbose sync information

SYNCNAME            Upstream name of target folder to sync locally (repeatable)

Examples:

  # generate a file index of favorite scripts or dev tools within a git repo
  [foo ~]$ cd ~/git/my-default-env/ && autoenv file-index bash python
  [foo ~/git/my-default-env]$ git add . && git commit -m 'blah blah' && git push

  # on another host, automatically initialize our bash stuff
  [bar ~]$ export AUTOENV_SYNC_URL=https://raw.githubusercontent.com/joesmith/my-default-env/master/
  [bar ~]$ autoenv sync bash
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

Automatically creates '.autoenv/{vars,aliases,cd.d,exit.d,init.d,up.d,run.d}/'
in ENV_DIR.
"
}


__autoenv_usage_forget() {
    lib_log "Usage: autoenv forget [ENV_NAME]"
    lib_log_raw "
Forget about an env (e.g. remove tracking from $__AUTOENV_ROOT/envs/). Inverse
of 'add'.
"
}


__autoenv_usage_file_index() {
    lib_log "Usage: autoenv file-index DIR [DIR2] [ARGS]"
    lib_log_raw "
Scan the directories given for files and scripts to generate an
'index.auto_env'. These can be uploaded alongside the files to use autoenv
'sync' to quickly download elsewhere (e.g. to quickly init a home directory).

Automatically skips .git dirs, vim swap files, and our index files.

ARGS

   -v|--verbose   Print verbose debugging information
   -d|--dryrun    Run without making changes
"
}


__autoenv_usage_edit() {
    lib_log "Usage: autoenv edit [WHAT] [WHICH]"
    lib_log_raw "
Edit active (based on depth) env, optionally specifying what/which things to
edit. Allows partial matches as long as arguments are unambiguous.
"
}

__autoenv_usage_go() {
    lib_log "Usage: autoenv go [-u|--up] [-r|--run] NAME"
    lib_log_raw "
Change directory to the env named and optionally start daemons and/or run
all scripts.
"
}


__autoenv_usage_favs() {
    lib_log "Usage: autoenv favs -e|--edit [FILTER]"
    lib_log_raw "
Prints a list of favorite commands w/ a shortcut to quickly execute it. If a
FILTER is given, only commands matching are shown. Using -e|--edit loads
the \$AUTOENV_ENV/.favs file for editing.
"
}


__autoenv_usage_run() {
    lib_log "Usage: autoenv run [-d|--dryrun] [SCRIPT] [SCRIPT]"
    lib_log_raw "
Run scripts from 'run.d/' in alphabetical order. Failures are printed to
stderr. May optionally run one or more specific scripts.  The working directory
will be the env dir.
"
}


__autoenv_usage_up() {
    lib_log "Usage: autoenv up [-d|--dryrun] [-f|--force] [DAEMON] [DAEMON]"
    lib_log_raw "
Run daemons from 'up.d/' in alphabetical order. Failures are printed to
stderr. May optionally run one or more specific daemons. Tracks '.\$daemon.pid'
files in the 'up.d/' dir. Skips daemons with PID files unless --force|-f is used.
The working directory will be the env dir.
"
}


__autoenv_usage_down() {
    lib_log "Usage: autoenv down [-d|--dryrun] [-c|--children] [DAEMON] [DAEMON]"
    lib_log_raw "
Stop daemons started from 'up.d/' in alphabetical order. Failures are printed to
stderr. May optionally stop one or more specific daemons. Uses '.\$daemon.pid'
files in the 'up.d/' dir to determine who is running. If --children|-c is given,
child processes will be terminated directly first, likely indirectly ending the
daemon.
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
    echo -e "\033[0;35;40m# ($__AUTOENV_TAG debug) \033[${color}m${1:-}\033[0m" >&2
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


# return the depth a venv was found at; 0 based index
__autoenv_get_depth() {
    local autoenv_dir="$1"
    local i
    for ((i=0; i<${#__AUTOENV_ENVS[*]}; i++)); do
        [ "${__AUTOENV_ENVS[i]}" = "$autoenv_dir" ] && {
            echo $i
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


# TODO: prune?
## print the depth a variable was found at; returns 1 if the env var was not defined
## $1=name of variable to search for
#__autoenv_var_depth() {
#    local to_match="$1"
#    local item
#    [ -z "$to_match" -o ${#__AUTOENV_VARS[*]} -gt 0 ] || return 1
#    for item in "${__AUTOENV_VARS[@]}"; do
#        if [ "${item##*:}" = "$to_match" ]; then
#            echo ${item%%:*}
#            return 0
#        fi
#    done
#    return 1
#}



# make an HTTP call and optionally save output to a file
# -o|--output PATH   Save output to a file; requires curl or wget
# $1 = URL to request
# $2... = extra arguments
__autoenv_http() {
    local agent=''
    local url=''
    local output_file='-'
    local args=()

    # get agent/url and any extra args
    while [ $# -gt 0 ]; do
        case "$1" in
            -o|--output)
                [ $# -ge 2 ] || {
                    lib_log_error "missing arg to __autoenv_http -o|--output"
                    return 1
                }
                output_file="$2"
                shift
                ;;
            *)
                if [ -z "$url" ]; then
                    url="$1"
                else
                    args+=("$1")
                fi
                ;;
        esac
        shift
    done

    [ -n "$url" ] || {
        lib_log_error "No URL given to download"
        return 1
    }

    agent="$(which curl)" &>/dev/null
    if [ -n "${agent[0]}" ]; then
        agent_args=($agent "$url" '--silent' '--fail' '-o' "$output_file")
    else
        # no curl? how about wget?
        agent=$(which wget) || {
            lib_log "Unable to locate 'curl' or 'wget' to download files."
            return 1
        }
        agent_args=("$agent" "$url" '--quiet' '-O' "$output_file")
    fi

    lib_cmd "${agent_args[@]}"
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

    # default to the name of the current folder
    [ -n "$env_name" ] || env_name=$(basename $(builtin cd "$env_root" && pwd -P))
    # avoid dupe names
    [ -L "$root_env_dir/envs/$env_name" ] && {
        lib_log_error "An env named '$env_name' already exists (env=$(readlink \"$root_env_dir/envs/$env_name\" 2>/dev/null))"
        return 1
    }
    # init the env
    lib_confirm "Create '$env_name' in '$env_root'?" || return 1
    mkdir -p "$env_root/.autoenv/"{vars,scripts,aliases,exit.d,init.d,up.d} || {
        lib_log_error "Failed to create autoenv dirs in '$env_root/.autoenv/'"
        return 1
    }
    __autoenv_add "$env_root" "$env_name" || return 1

    # let the user know about it
    lib_log "** created env '$env_name'" '1;32;40'
    lib_log "  - tracked at: '$root_env_dir/envs/$env_name'" '1;32;40'
    lib_log "** run 'autoenv edit [what] [which]' to customize" '1;32;40'
}


# add an existing .autoenv dir to $__AUTOENV_ROOT/.autoenv/envs and sets .autoenv/.name; ensures all autoenv dirs exist[
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
# $1 = env name
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


__autoenv_favs() {
    # DREAM: support imports for sharing common stuff
    local favs_file="$AUTOENV_ENV/.autoenv/favs"
    [ "${1:-}" = '-e' -o "${1:-}" = '--edit' ] && {
        [ $# -ge 2 ] && lib_log_error "Ignoring extra FILTER argument when editing favs."
        "$EDITOR" "$favs_file"
        return $?
    }
    [ -s "$favs_file" ] || {
        lib_log_error "No favs exist in '$favs_file' yet; edit with \`ae favs -e\`."
        return
    }

    local keys chars favs i j line filter cmd
    chars=( {a..z} {A..Z} )
    i=0
    filter="${1:-}"

    # Curate two arrays to track shortcut + command for each fav. Print our
    # favs as we go, all pretty-like.
    echo -e "\033[1;36m=== Favorites: ==========="
    cmd=""
    cmd_pretty=""
    while IFS= read -r line; do
        # Reflect back formatting/comments:
        [ -z "$line" ] && { echo; continue; }
        [[ "$line" =~ ^[[:space:]]*# ]] && { echo -e "\033[0;36m$line\033[0m"; continue; }
        # Accumulate multi-line commmands as needed
        if [ "${line%\\}" = "$line" ]; then  # trailing \, take it and map it
            cmd+="$line"
            cmd_pretty+="$line"
        else # we have a trailing \
            cmd+="${line%\\} "
            cmd_pretty+="$line"$'\n  '
            continue
        fi
        # Filter out any mismatches, if arg given.
        [ -n "$filter" -a "${cmd%%$filter*}" = "$cmd" ] && {
            cmd=''
            cmd_pretty=''
            continue
        }
        [ -n "$filter" ] && {
            local _highlight=$'\033[1;33m'
            local _normal=$'\033[0m'
            cmd_pretty="${cmd_pretty//$filter/${_highlight}$filter${_normal}}"
        }
        [ $i -gt 52 ] && {
            lib_log_error "More than 52 favs in $favs_file; ignoring extras."
            break
        }
        favs[i]="$cmd"
        keys[i]="${chars[i]}"
        echo -e "\033[0;32m[\033[1;32m${keys[i]}\033[0;32m]\033[0m ${cmd_pretty}"
        cmd=''
        cmd_pretty=''
        i=$((i + 1))
    done < "$favs_file"

    # Prompt for single key
    echo -e "\n\033[1;36m==========================\033[0m"
    echo -en "\033[1;32mChoose (^c,empty=cancel) > \033[0m"
    IFS= read -r -n1 choice || return 1
    echo
    [ -z "$choice" ] && return 1

    # Match key to run fav
    for ((j=0; j<i; j++)); do
        if [[ "$choice" == "${keys[j]}" ]]; then
            # Subshell to control working dir and add some process isolation.
            (
                cd "$AUTOENV_ENV" || exit 1
                eval "${favs[j]}"
            )
            return $?
        fi
    done

    echo -e "\033[1;31mInvalid selection.\033[0m"
    return 1
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


# use nohup and tie-off std{in/out/err} to execute each daemon in a subshell
# runs '.autoenv/up.d/*' in alphabetical order
# usage: ae up [ARGS] ENV_DIR [DAEMON] [DAEMON]
__autoenv_up() {
    local env_dir
    local up_dir
    local daemon
    local pid_file
    local dry_run=0
    local daemons=()
    local pid

    while [ $# -gt 0 ]; do
        case "$1" in
            -d|--dryrun)
                dry_run=1
                ;;
            *)
                [ -z "$env_dir" ] \
                    && env_dir="$1" \
                    || daemons+=("$1")
                ;;
        esac
        shift
    done
    [ -n "$env_dir" ] || {
        lib_log_error "No env dir specified"
        return 1
    }
    up_dir="$env_dir/.autoenv/up.d"
    [ -d "$up_dir" ] || return 0

    find "$up_dir" -maxdepth 1 -perm +111 \( -type f -o -type l \) \! -name .\* \
        | sort \
        | while read daemon; do
            daemon=$(basename "$daemon")
            # want specific ones only?
            if [ ${#daemons[*]} -gt 0 ]; then
                lib_in_list "$daemon" -- "${daemons[@]}" || continue
            fi
            pid_file="$up_dir/.$daemon.pid"
            [ -s "$pid_file" ] && {
                lib_log "$daemon is already running (PID: $(<"$pid_file"))"
                continue
            }
            [ $dry_run -eq 1 ] && {
                lib_log "\033[0;36;40mDRY RUN:\033[0;34;40m AUTOENV_ENV=\"$env_dir\" AUTOENV_PENV=\"$env_dir\" nohup \"$up_dir/$daemon\" &>/dev/null </dev/null &"
                continue
            }
            lib_log "starting: $daemon"
            (
                cd "$env_dir" || exit 1
                AUTOENV_ENV="$env_dir" AUTOENV_PENV="$env_dir" \
                    nohup "$up_dir/$daemon" &>/dev/null </dev/null &
                pid=$!
                echo $pid > "$pid_file"
                wait $pid
                lib_log "ended: $daemon (retval=$?, pid=$(<"$pid_file"))"
                rm -f "$pid_file" &>/dev/null
            ) &
        done

    return 0
}


# sends a sig-kill to each .pid files in autoenv/up.d
# usage: ae down [ARGS] ENV_DIR [DAEMON] [DAEMON]
__autoenv_down() {
    local env_dir
    local up_dir
    local daemon
    local pid_file
    local pid
    local i
    local dry_run=0
    local daemons=()
    local children
    local children_first=0
    local c_pids=()

    while [ $# -gt 0 ]; do
        case "$1" in
            -d|--dryrun)
                dry_run=1
                ;;
            -c|--children)
                children_first=1
                ;;
            *)
                [ -z "$env_dir" ] \
                    && env_dir="$1" \
                    || daemons+=("$1")
                ;;
        esac
        shift
    done
    [ -n "$env_dir" ] || {
        lib_log_error "No env dir specified"
        return 1
    }
    up_dir="$env_dir/.autoenv/up.d"
    [ -d "$up_dir" ] || return 0

    find "$up_dir" -maxdepth 1 -name .\*.pid | sort | while read pid_file; do
        pid_file="$(basename "$pid_file")"
        pid=$(<"$up_dir/$pid_file")
        daemon="${pid_file:1:${#pid_file}-5}"
        if [ ${#daemons[*]} -gt 0 ]; then
            lib_in_list "$daemon" -- "${daemons[@]}" || continue
        fi
        # clean up crashed PIDs
        ps -p "$pid" &>/dev/null || {
            lib_log_error "No daemon running for $daemon (PID $pid); clearing '$pid_file'"
            rm -f "$pid_file" || lib_log_error "Failed to remove PID file: $pid_file"
            continue
        }
        children="$(ps -o ppid,pid,command | grep "^$pid " | cut -f2- -d ' ')"
        c_pids=($(echo "$children" | awk '{print $1}'))
        lib_log "killing $daemon (PID $pid); children:\n$children"
        [ $dry_run -eq 1 ] && {
            [ ${#c_pids[*]} -gt 0 -a $children_first -eq 1 ] && \
                lib_log "\033[0;36;40mDRY RUN:\033[0;34;40m kill ${c_pids[*]}"
            lib_log "\033[0;36;40mDRY RUN:\033[0;34;40m kill $pid"
            continue
        }
        [ ${#c_pids[*]} -gt 0 -a $children_first -eq 1 ] && {
            kill "${c_pids[@]}"
        }
        kill "$pid" &>/dev/null
    done

    return 0
}


# run each script in the directory, in alphabetical order
# $1 = env dir to run scripts from
# -d|--dryrun = just print what would be ran
# $2... = specific things to run, if any
__autoenv_run() {
    local env_dir
    local run_dir
    local script
    local dry_run=0
    local scripts=()

    while [ $# -gt 0 ]; do
        case "$1" in
            -d|--dryrun)
                dry_run=1
                ;;
            *)
                [ -z "$env_dir" ] \
                    && env_dir="$1" \
                    || scripts+=("$1")
                ;;
        esac
        shift
    done
    [ -n "$env_dir" ] || {
        lib_log_error "No env dir specified"
        return 1
    }
    run_dir="$env_dir/.autoenv/run.d"
    [ -d "$run_dir" ] || return 0

    find "$run_dir" -maxdepth 1 -perm +111 \( -type f -o -type l \) \! -name .\* \
        | sort \
        | while read script; do
            script=$(basename "$script")
            if [ ${#scripts[*]} -gt 0 ]; then
                 lib_in_list "$script" -- "${scripts[@]}" || continue
            fi
            [ $dry_run -eq 1 ] && {
                lib_log "\033[0;36;40mDRY RUN:\033[0;34;40m AUTOENV_ENV=\"$env_dir\" \"$run_dir/$script\""
                continue
            }
            lib_log "running '$script'"
            AUTOENV_ENV="$env_dir" "$run_dir/$script"
        done

    return 0
}


# sync any env external resources based on $AUTOENV_SYNC_URL
# $1 = base dir to sync to
# $2..N = sync target names (e.g. for "GET $1/$2/index.autoenv")
# $AUTOENV_SYNC_URL = env var to URL containing sync dirs w/ index.autoenv files
__autoenv_sync() {
    local target_dir
    local verbose=0
    local force=0
    local shasum
    local target_names=()
    local sync_src="${AUTOENV_SYNC_URL:-}"
    local dryrun=0

    # sanity checks!
    [ -n "$sync_src" ] || {
        lib_log_error "Sync failed; Export 'AUTOENV_SYNC_URL' to a URL containing autoenv sync directories."
        return 1
    }
    [ $# -ge 2 ] || {
        lib_log_error "At least two arguments are required."
        __autoenv_usage_sync
        return 1
    }
    shasum="$(which shasum 2>/dev/null) -a 1" \
        || shasum=$(which sha1sum 2>/dev/null) \
        || {
            lib_log_error "Failed to locate 'shasum' or 'sha1sum' binary."
            return 1
        }

    # get our target dir and the sync target names + misc args
    target_dir="$1"; shift
    while [ $# -gt 0 ]; do
        case "$1" in
            -v|--verbose)
                verbose=1
                ;;
            -f|--force)
                force=1
                ;;
            -d|--dryrun)
                dryrun=1
                ;;
            *)
                target_names+=("$1")
        esac
        shift
    done

    [ $(lib_prompt "Sync \033[1;37m${target_names[*]}\033[0m to '$target_dir'" -n 1 y n) = n ] && {
        lib_log 'Aborting sync'
        return 1
    }

    # do everything in subshells to minimize env polution
    (
    local target i base_dir file_name exec_bit checksum path tmp_path \
        new_checksum old_checksum preview_lines file_changed
    AUTOENV=0  # disable automated stuff while moving around
    cd "$target_dir" || {
        lib_log "Failed to change to sync directory '$target_dir'."
        exit 1
    }
    [ $verbose -eq 1 ] && { AUTOENV_DEBUG=1; LIB_VERBOSE=1; }
    [ $dryrun -eq 1 ] && { LIB_DRYRUN=1; }

    # for each target download the autoenv index and listed files
    for ((i=0; i<${#target_names[*]}; i++)); do

        target="${target_names[i]}"
        # kill any extra slashes at the end
        target="${target%%/}"
        __autoenv_debug "Downloading index list for '$target'"

        # download all the files listed in the index
        __autoenv_http "$sync_src/$target/index.autoenv" | while read exec_bit checksum path; do
            # normalize the path to clean extra slashes, preceding periods
            path="$(echo "$path" | sed 's#//*#/#g' | sed 's#^\./##')"
            base_dir="$(dirname "$path")" || lib_fail "Failed to get base directory of '$path'."
            file_name="$(basename "$path")" || lib_fail "Failed to get file name of '$path'."
            tmp_path=".$file_name.autoenv-sync.$$"

            # before we download, see if we even need a new version
            file_changed=1
            if [ -e "$base_dir/$file_name" -a $force -eq 0 ]; then
                old_checksum=$($shasum "$base_dir/$file_name" | awk '{print $1}') \
                    || lib_fail "Failed to generate checksum for existing copy of '$path'."
                if [ "$old_checksum" = "$checksum" ]; then
                    __autoenv_debug "-- skipping download of unchanged file: '$path'"
                    file_changed=0
                fi
            fi

            # only download files we need updates on
            [ $file_changed -eq 1 ] && {
                __autoenv_debug "-- downloading file: '$path'"
                __autoenv_http "$sync_src/$target/$path" -o "$tmp_path" || {
                    rm "$tmp_path" &>/dev/null
                    lib_fail "Failed to download '$sync_src/$target/$path' to '$tmp_path'."
                }
                # does the checksum match?
                new_checksum=$($shasum "$tmp_path" | awk '{print $1}') \
                    || lib_fail "Failed to generate checksum for '$path'."
                if [ "$new_checksum" != "$checksum" ]; then
                    preview_lines=6
                    __autoenv_debug "-- File checksum mismatch (first $preview_lines lines)"
                    __autoenv_debug "------------------------------------------"
                    head -n $preview_lines "$tmp_path" >&2
                    __autoenv_debug "------------------------------------------"
                    # file failed to download... odd. Permissions/misconfig, perhaps?
                    rm "$tmp_path" &>/dev/null
                    lib_fail "Checksum error on '$path' from '$target' (expected: $checksum, got: $new_checksum)."
                fi
            }

            if [ $file_changed -eq 0 ]; then
                # regardless if the file changed make sure the exec bit is set right
                (
                    if [ $exec_bit = '1' -a ! -x "$base_dir/$file_name" ]; then
                        lib_cmd chmod u+x "$base_dir/$file_name" || lib_fail
                    fi
                    if [ $exec_bit = '0' -a -x "$base_dir/$file_name" ]; then
                        lib_cmd chmod u-x "$base_dir/$file_name" || lib_fail
                    fi
                ) || {
                    [ -f "$tmp_path" ] && rm "$tmp_path" &>/dev/null
                    lib_fail "Failed to chmod 'u+x' file '$base_dir/$file_name'."
                }
            else
                # prepare exec bit if needed before moving it into place
                if [ $exec_bit = '1' ]; then
                    lib_cmd chmod u+x "$tmp_path" \
                        || {
                            rm "$tmp_path" &>/dev/null
                            lib_fail "Failed to chmod 'u+x' file '$tmp_path'."
                        }
                fi
                # create any leading directories if needed
                if [ "$base_dir" != '.' ]; then
                    lib_cmd mkdir -p "$base_dir" \
                        || {
                            rm "$tmp_path" &>/dev/null
                            lib_fail "Failed to create base directory '$base_dir'."
                        }
                fi
                # and move it into place
                lib_cmd mv "$tmp_path" "$base_dir/$file_name" || {
                    rm "$tmp_path" &>/dev/null
                    lib_fail "Failed to move '$tmp_path' to '$base_dir/$file_name'."
                }
            fi

            # didn't change or it was a dry run? still be sure to cleanup
            [ -f "$tmp_path" ] && rm "$tmp_path" &>/dev/null

        done

    done
    )
}


# generate 'index.auto_env' for each dir given; ignores .git dirs, our idnex
# files, and vim swap files
# $1..N = directories to index
# -v|--verbose = print verbose info about indexing
# -d|--dryrun  = print information about changes without doing anything
__autoenv_file_index() {
    local paths=()
    local shasum
    local force=0
    local verbose=0
    local dryrun=0
    local dir

    shasum="$(which shasum 2>/dev/null)"
    if [ "${#shasum}" -gt 0 ]; then
        shasum_args=("$shasum" '-a' 1)
    else
        shasum="$(which sha1sum 2>/dev/null)" || {
            lib_log_error "Failed to locate 'shasum' or 'sha1sum' binary."
            return 1
        }
        shasum_args=("$shasum")
    fi

    while [ $# -gt 0 ]; do
        case "$1" in
            -v|--verbose)
                verbose=1
                ;;
            -d|--dryrun)
                dryrun=1
                ;;
            *)
                [ -d "$1" ] || {
                    lib_log_error "Invalid path: '$1'"
                    return 1
                }
                paths+=("$1")
                ;;
        esac
        shift
    done
    [ ${#paths[*]} -gt 0 ] || {
        lib_log_error "No paths given to do file indexing on"
        return 1
    }

    for dir in "${paths[@]}"; do
        (
            local scripts name exec_bit lines checksum path
            [ $verbose -eq 1 ] && AUTOENV_DEBUG=1
            __autoenv_debug "Generating index '$(basename $dir)/index.auto_env'"
            [ -d "$dir" ] || lib_fail "Directory '$dir' does not exist"
            builtin cd "$dir" || lib_fail "Failed to change to '$dir'."
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
                lib_fail "Failed to generate checksum list for directory '$dir'."
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
                __autoenv_debug " - $path (exec=$exec_bit, checksum=$checksum)"
                echo "$exec_bit  $checksum  $path"
            done < .index.autoenv.$$ > .index.autoenv.$$.done
            if [ $? -ne 0 ]; then
                rm .index.autoenv.$$ &>/dev/null
                rm .index.autoenv.$$.done &>/dev/null
                lib_fail "Failed to generate index file for '$dir'."
            fi
            # put our new files in place
            rm .index.autoenv.$$ &>/dev/null
            lines=$(wc -l .index.autoenv.$$.done | awk '{print $1}')
            [ $dryrun -eq 1 ] && {
                rm -f .index.autoenv.$$.done
            } || {
                mv .index.autoenv.$$.done index.autoenv || {
                    rm .index.autoenv.$$.done &>/dev/null
                    lib_fail "Failed to move autoenv index '$dir/index.autoenv'."
                }
            }
            lib_log "index-sync '$dir' done (files: $lines, scripts: $scripts)"
        ) || {
            lib_log_error "Failed to index '$dir'"
            return 1
        }
    done
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


# print information about the current env (name, root, aliases, vars, etc)
# $1 = which env, based on depth (e.g. 0 is first)
__autoenv_log_env_info() {
    local depth="$1"
    local i item
    local items
    local pid
    local env_dir="${__AUTOENV_ENVS[depth]}"

    lib_log "$(($depth + 1)). ─═« $(lib_color lightcyan "$(<"$env_dir/.autoenv/.name")" cyan) »═─ $(lib_color white "$env_dir" white)" '0;36'

    items=()
    for ((i=0; i<${#__AUTOENV_VARS[*]}; i++)); do
        item="${__AUTOENV_VARS[i]}"
        [ "${item%%:*}" = "$depth" ] && items+=("${item##*:}")
    done
    [ ${#items[*]} -gt 0 ] && lib_cols --min \
        -h "\033[0;32m  ░▒▌EnvVars▐▒░ " \
        -c lime \
        "${items[@]}" >&2

    items=()
    for ((i=0; i<${#__AUTOENV_ALIASES[*]}; i++)); do
        item="${__AUTOENV_ALIASES[i]}"
        [ "${item%%:*}" = "$depth" ] && items+=("${item##*:}")
    done
    [ ${#items[*]} -gt 0 ] && lib_cols --min \
        -h "\033[0;33m  ░▒▌Aliases▐▒░ " \
        -c lemon \
        "${items[@]}"

    items=()
    for item in "$env_dir/.autoenv/scripts/"*; do
        # ignore non-scripts and potential unmatched wildcard
        [ -x "$item" ] && {
            items+=("$(basename "$item")")
        }
    done
    [ ${#items[*]} -gt 0 ] && lib_cols --min \
         -h "\033[0;31m  ░▒▌Scripts▐▒░ " \
         -c pink \
         "${items[@]}"


    items=()
    for item in "$env_dir/.autoenv/up.d/"*; do
        # ignore non-scripts and potential unmatched wildcard
        [ -x "$item" ] && {
            item="$(basename "$item")"
            [ -s "$env_dir/.autoenv/up.d/.$item.pid" ] && {
                pid=$(<"$env_dir/.autoenv/up.d/.$item.pid")
                ps -p "$pid" &>/dev/null \
                    && item="$item ($pid)" \
                    || item="$item ($pid?)"
            }
            items+=("$item")
        }
    done
    [ ${#items[*]} -gt 0 ] && lib_cols --min \
         -h "\033[0;35m  ░▒▌Daemons▐▒░ " \
         -c fushia \
         "${items[@]}"
}


# print information about each active env
__autoenv_env_info() {
    local env_dir i
    local envs="$(ls -1 "$__AUTOENV_ROOT/.autoenv/envs" 2>/dev/null | tr "\n" " ")"
    lib_cols --min -d "\033[0;30;44m ░ " \
        -p "\033[0;34m░▒▓" \
        -h "\033[0;30;44mENVS: " \
        -s "\033[0;34m▓▒░" \
        -c '1;37;44' \
        $envs
    for ((i=0; i<${#__AUTOENV_ENVS[*]}; i++)); do
        env_dir="${__AUTOENV_ENVS[i]}"
        __autoenv_log_env_info $i
    done
}


# initialize an env; ensure nesting is handled properly based on dir depth
# $1 = path to autoenv dir to init
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
            __AUTOENV_VARS+=("$depth:$name")
            # does a nested env have this same var defined?
            item="$(__autoenv_first_above "$name" "$depth" "${__AUTOENV_VARS[@]}")"
            [ -n "$item" ] && continue
            export "$name"="$(<"$env_dir/.autoenv/vars/$name")"
        done
    }

    # aliases
    [ -d "$env_dir/.autoenv/aliases" ] && {
        for name in $(ls -1 "$env_dir/.autoenv/aliases/"); do
            __AUTOENV_ALIASES+=("$depth:$name")
            # does a nested env have this same alias defined?
            item="$(__autoenv_first_above "$name" "$depth" "${__AUTOENV_ALIASES[@]}")"
            [ -n "$item" ] && continue
            alias "$name"="AUTOENV_PENV='$env_dir' $(<"$env_dir/.autoenv/aliases/$name")"
        done
    }

    # scripts
    [ -d "$env_dir/.autoenv/scripts" ] && {
        # if we're more than on level deep we need to be before our parent
        # ... that is, the first parent with custom scripts
        __autoenv_path_prepend_scripts "$env_dir/.autoenv/scripts" $depth
    }

    # report our env as setup prior to running init scripts
    __autoenv_log_env_info $depth

    # and finally, our init scripts
    [ -d "$env_dir/.autoenv/init.d" ] && {
        for name in $(ls -1 "$env_dir/.autoenv/init.d/"); do
            lib_log "   $(lib_color purple '»»' fushia) . init.d/$name" '1;35;40'
            # many scripts use sloppy var handling, so ignore this
            set +u
            source "$env_dir/.autoenv/init.d/$name" \
                || lib_log_error "Failed to run env init script '$name'"
            set -u
        done
        unset AUTOENV_ENV
    }

    # we may have init'd out-of-order, so always point to the last env
    export AUTOENV_ENV="${__AUTOENV_ENVS[@]: -1}"

    return 0
}

# de-init an active env, resetting PATH, aliases, env vars, etc
# $1 = path to authenv dir to exit
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
            lib_log "   $(lib_color purple '««' fushia) . exit.d/$name" '0;35;40'
            set +u
            source "$env_dir/.autoenv/exit.d/$name"
            set -u
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
                env_dir="${scan_dir##$__AUTOENV_ROOT/}"
                # ensure we have a name and thus have been "added" already
                [ -s "$scan_dir/.autoenv/.name" ] || {
                    lib_log "Untracked env: '$env_dir'; add with: ae add \"$scan_dir\" [NAME]" '1;33;40'
                    exit 1
                }
                env_name=$(<"$scan_dir/.autoenv/.name") || {
                    lib_log_error "Failed to read .name from '$scan_dir' env"
                    exit 1
                }
                # ensure the symlink is valid too
                real_scan_dir=$(builtin cd "$scan_dir" && pwd -P)
                [ -x "$root_env_dir/$env_name" ] || {
                    lib_log_error "Untracked env: '$env_dir' ('$root_env_dir/$env_name' does not exist); add with: ae add '$scan_dir' [NAME]" '1;33;40'
                    exit 1
                }
                [ "$(readlink "$root_env_dir/$env_name")" = $(builtin cd "$real_scan_dir" && pwd -P) ] || {
                    lib_log_error "Name mismatch: $root_env_dir/$env_name points elsewhere; fix .autoenv/.name or run: ae forget '$env_name'"
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
        # misc + env management
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
                __autoenv_usage_create
                return
            }
            __autoenv_create "$@" || {
                lib_log_error "failed to create env $@"
                return 1
            }
            __autoenv_scan
            ;;
        edit)
            __autoenv_edit "$@" || return 1
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
        favs)
            lib_in_list "-h" "--help" -- "$@" && {
                __autoenv_usage_favs
                return
            }
            __autoenv_favs "$@" || return 1
            ;;
        go)
            lib_in_list "-h" "--help" -- "$@" && {
                __autoenv_usage_go
                return
            }
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
        info)
            __autoenv_env_info
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

        # daemon-like hacks
        run)
            lib_in_list "-h" "--help" -- "$@" && {
                __autoenv_usage_run
                return
            }
            [ ${AUTOENV:-1} -ne 0 ] && \
                __autoenv_run "${__AUTOENV_ENVS[${#__AUTOENV_ENVS[*]}-1]}" "$@"
            ;;
        up)
            lib_in_list "-h" "--help" -- "$@" && {
                __autoenv_usage_up
                return
            }
            [ ${AUTOENV:-1} -ne 0 ] && \
                __autoenv_up "${__AUTOENV_ENVS[${#__AUTOENV_ENVS[*]}-1]}" "$@"
            ;;
        down)
            lib_in_list "-h" "--help" -- "$@" && {
                __autoenv_usage_down
                return
            }
            [ ${AUTOENV:-1} -ne 0 ] && \
                __autoenv_down "${__AUTOENV_ENVS[${#__AUTOENV_ENVS[*]}-1]}" "$@"
            ;;

        # syncronization commands
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
        file-index)
            [ $# -gt 0 ] || {
                lib_log_error "file-index usage: DIR [DIR2]"
                __autoenv_usage_file_index
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
