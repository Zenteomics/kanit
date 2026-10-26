# bash completion for workz: source this file, or put it in
# ~/.local/share/bash-completion/completions/workz.
_workz() {
    local cur prev cmd wf i words
    cur=${COMP_WORDS[COMP_CWORD]}
    prev=${COMP_WORDS[COMP_CWORD-1]}
    cmd=${COMP_WORDS[1]}
    local commands="init validate plan dry-run explain graph run control watch status logs report verify clean completion help version"
    if [ "$COMP_CWORD" = 1 ]; then
        COMPREPLY=($(compgen -W "$commands" -- "$cur"))
        return
    fi
    # The workflow file named so far, for rule names, and the other words.
    words=()
    for ((i = 2; i < COMP_CWORD; i++)); do
        case ${COMP_WORDS[i]} in
            *.toml | *.oxoflow) wf=${COMP_WORDS[i]} ;;
            -*) ;;
            *) words+=("${COMP_WORDS[i]}") ;;
        esac
    done
    case $prev in
        -t | --target | --rerun-rule)
            COMPREPLY=($(compgen -W "$(workz __rules $wf 2> /dev/null)" -- "$cur"))
            return ;;
        -d | --workdir) COMPREPLY=($(compgen -d -- "$cur")); return ;;
        --input-manifest) COMPREPLY=($(compgen -f -- "$cur")); return ;;
        --format) COMPREPLY=($(compgen -W "tsv json html" -- "$cur")); return ;;
    esac
    local opts="-h --help -d --workdir"
    case $cmd in
        run) opts="$opts -t --target -j --jobs --max-threads --max-memory -k --keep-going -r --retry --timeout --rerun --rerun-rule --input-manifest --pass-env --grace --slice --no-isolation -q --quiet --json --no-color" ;;
        plan | dry-run) opts="$opts -t --target --summary --rerun --rerun-rule --pass-env" ;;
        explain) opts="$opts -t --target --rerun --rerun-rule --pass-env" ;;
        validate | graph) opts="$opts -t --target" ;;
        verify) opts="$opts -t --target --content" ;;
        watch) opts="$opts --once --interval" ;;
        status) opts="$opts --history --json" ;;
        report) opts="$opts --launch --format --bottlenecks --suggest --compare" ;;
        logs) opts="$opts --launch --attempt --stdout --stderr -f --follow" ;;
        clean) opts="$opts --keep --dry-run" ;;
        init | control) opts="-h --help" ;;
        completion) COMPREPLY=($(compgen -W "bash" -- "$cur")); return ;;
        help) COMPREPLY=($(compgen -W "$commands" -- "$cur")); return ;;
    esac
    if [[ $cur == -* ]]; then
        COMPREPLY=($(compgen -W "$opts" -- "$cur"))
    elif [ "$cmd" = control ] && [ ${#words[@]} = 0 ]; then
        COMPREPLY=($(compgen -W "stop retry cancel" -- "$cur"))
    elif { [ "$cmd" = control ] && [ ${#words[@]} = 1 ] && [ "${words[0]}" != cancel ]; } || { [ "$cmd" = explain ] && [ -n "$wf" ]; } || [ "$cmd" = logs ]; then
        COMPREPLY=($(compgen -W "$(workz __rules $wf 2> /dev/null)" -- "$cur"))
    elif [ "$cmd" = control ]; then
        COMPREPLY=()
    else
        COMPREPLY=($(compgen -f -- "$cur"))
    fi
}
complete -F _workz workz
