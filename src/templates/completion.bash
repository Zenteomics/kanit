# bash completion for workz: source this file, or put it in
# ~/.local/share/bash-completion/completions/workz.
_workz() {
    local cur prev cmd wf i
    cur=${COMP_WORDS[COMP_CWORD]}
    prev=${COMP_WORDS[COMP_CWORD-1]}
    cmd=${COMP_WORDS[1]}
    if [ "$COMP_CWORD" = 1 ]; then
        COMPREPLY=($(compgen -W "validate plan dry-run explain graph run watch status verify report logs clean control init completion version" -- "$cur"))
        return
    fi
    # The workflow file named so far, for rule names.
    for ((i = 2; i < COMP_CWORD; i++)); do
        case ${COMP_WORDS[i]} in *.toml | *.oxoflow) wf=${COMP_WORDS[i]} ;; esac
    done
    case $prev in
        -t | --target | --rerun-rule)
            COMPREPLY=($(compgen -W "$(workz __rules $wf 2> /dev/null)" -- "$cur"))
            return ;;
        -d | --workdir) COMPREPLY=($(compgen -d -- "$cur")); return ;;
        --input-manifest) COMPREPLY=($(compgen -f -- "$cur")); return ;;
        --format) COMPREPLY=($(compgen -W "tsv json html" -- "$cur")); return ;;
    esac
    local opts="-d --workdir -t --target"
    case $cmd in
        run) opts="$opts -j --jobs --max-threads --max-memory -k --keep-going -r --retry --timeout --rerun --rerun-rule --input-manifest --pass-env --grace --slice --no-isolation -q --quiet" ;;
        plan | dry-run) opts="$opts --summary --rerun --rerun-rule --pass-env" ;;
        explain) opts="$opts --rerun --rerun-rule --pass-env" ;;
        watch) opts="$opts --once --interval" ;;
        status) opts="$opts --history" ;;
        verify) opts="$opts --content" ;;
        report) opts="$opts --launch --format --bottlenecks" ;;
        logs) opts="$opts --launch --attempt --stdout --stderr -f --follow" ;;
        clean) opts="$opts --keep --dry-run" ;;
        completion) COMPREPLY=($(compgen -W "bash" -- "$cur")); return ;;
    esac
    if [[ $cur == -* ]]; then
        COMPREPLY=($(compgen -W "$opts" -- "$cur"))
    elif [ -n "$wf" ] && { [ "$cmd" = explain ] || [ "$cmd" = logs ]; }; then
        COMPREPLY=($(compgen -W "$(workz __rules $wf 2> /dev/null)" -- "$cur"))
    else
        COMPREPLY=($(compgen -f -- "$cur"))
    fi
}
complete -F _workz workz
