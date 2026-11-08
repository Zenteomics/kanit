# bash completion for kanit: source this file, or put it in
# ~/.local/share/bash-completion/completions/kanit.
_kanit() {
    local cur prev cmd wf wd i words
    cur=${COMP_WORDS[COMP_CWORD]}
    prev=${COMP_WORDS[COMP_CWORD-1]}
    cmd=${COMP_WORDS[1]}
    local commands="init prepare schema validate plan explain graph run control watch status logs report verify clean completion help version"
    if [ "$COMP_CWORD" = 1 ]; then
        COMPREPLY=($(compgen -W "$commands" -- "$cur"))
        return
    fi
    words=()
    for ((i = 2; i < COMP_CWORD; i++)); do
        case ${COMP_WORDS[i]} in
            -d | --workdir) wd=${COMP_WORDS[i+1]}; ((i++)) ;;
            -t | --target | --rerun-rule | --pass-env | -j | --jobs | --max-threads | --max-memory | -r | --retry | \
                --timeout | --grace | --input-manifest | --slice | --launch | --attempt | --format | -o | --output | --params | \
                --compare | --keep | --interval | --threads | --layer | --by | --focus | --why | --users) ((i++)) ;;
            *.toml | *.toml\" | *.toml\') wf=${COMP_WORDS[i]//\\/}; wf=${wf#[\"\']}; wf=${wf%[\"\']} ;;
            -*) ;;
            *) words+=("${COMP_WORDS[i]}") ;;
        esac
    done
    if [ -z "$wd" ]; then
        if [ -n "$wf" ]; then wd=$(dirname "$wf"); else wd=.; fi
    fi
    case $prev in
        -t | --target | --rerun-rule | --focus)
            COMPREPLY=($(compgen -W "$(kanit __rules ${wf:+"$wf"} 2> /dev/null)" -- "$cur"))
            return ;;
        --pass-env) COMPREPLY=($(compgen -e -- "$cur")); return ;;
        -j | --jobs | --max-threads | --max-memory | -r | --retry | --timeout | --grace | --slice | --attempt | \
            --keep | --interval | --threads | --why | --users)
            COMPREPLY=(); return ;;
        -d | --workdir) compopt -o filenames 2> /dev/null; mapfile -t COMPREPLY < <(compgen -d -- "$cur"); return ;;
        --input-manifest | -o | --output | --params) compopt -o filenames 2> /dev/null; mapfile -t COMPREPLY < <(compgen -f -- "$cur"); return ;;
        --format)
            if [ "$cmd" = graph ]; then COMPREPLY=($(compgen -W "text dot json" -- "$cur"))
            else COMPREPLY=($(compgen -W "tsv json html" -- "$cur")); fi
            return ;;
        --layer) COMPREPLY=($(compgen -W "rules files resources all" -- "$cur")); return ;;
        --by) COMPREPLY=($(compgen -W "step" -- "$cur")); return ;;
        --launch) COMPREPLY=($(compgen -W "$(ls "$wd/.workz/launches" 2> /dev/null)" -- "$cur")); return ;;
        --compare)
            compopt -o filenames 2> /dev/null
            mapfile -t COMPREPLY < <(compgen -W "$(ls "$wd/.workz/launches" 2> /dev/null)" -- "$cur"; compgen -d -- "$cur")
            return ;;
    esac
    local opts="-h --help -d --workdir"
    case $cmd in
        run) opts="$opts -t --target -j --jobs --max-threads --max-memory -k --keep-going -r --retry --timeout --rerun --rerun-rule --input-manifest --pass-env --threads --grace --slice --no-isolation -q --quiet -v --verbose --json --no-color" ;;
        plan | dry-run) opts="$opts -t --target --summary --budget --max-threads --max-memory --rerun --rerun-rule --input-manifest --pass-env --threads" ;;
        explain) opts="$opts -t --target --rerun --rerun-rule --input-manifest --pass-env --threads" ;;
        validate) opts="$opts -t --target --inputs" ;;
        graph) opts="$opts -t --target --layer --by --focus --why --users --format" ;;
        prepare) opts="-h --help -o --output --params --check" ;;
        schema | version) opts="-h --help" ;;
        verify) opts="$opts -t --target --content" ;;
        watch) opts="$opts --once --interval --launch --no-color" ;;
        status) opts="$opts --history --json --launch --no-color" ;;
        report) opts="$opts --launch --format --json --bottlenecks --suggest --compare --methods -o --output" ;;
        logs) opts="$opts --launch --attempt --stdout --stderr -f --follow" ;;
        clean) opts="$opts --keep --previous --dry-run" ;;
        control) ;;
        init) opts="-h --help --template" ;;
        completion) COMPREPLY=($(compgen -W "bash" -- "$cur")); return ;;
        help) COMPREPLY=($(compgen -W "$commands" -- "$cur")); return ;;
    esac
    if [[ $cur == -* ]]; then
        COMPREPLY=($(compgen -W "$opts" -- "$cur"))
    elif [ "$cmd" = control ] && [ ${#words[@]} = 0 ]; then
        COMPREPLY=($(compgen -W "stop retry cancel" -- "$cur"))
    elif [ "$cmd" = control ] && [ ${#words[@]} = 1 ] && [ "${words[0]}" != cancel ]; then
        COMPREPLY=($(compgen -W "$(kanit __rules ${wf:+"$wf"} 2> /dev/null)" -- "$cur"))
    elif [ "$cmd" = control ]; then
        COMPREPLY=()
    elif { [ "$cmd" = explain ] || [ "$cmd" = logs ]; } && [ ${#words[@]} = 0 ]; then
        COMPREPLY=($(compgen -W "$(kanit __rules ${wf:+"$wf"} 2> /dev/null)" -- "$cur"))
        if [ -z "$wf" ]; then
            compopt -o filenames 2> /dev/null
            mapfile -t -O "${#COMPREPLY[@]}" COMPREPLY < <(compgen -f -X "!*.toml" -- "$cur")
        fi
    elif [ "$cmd" = explain ] || [ "$cmd" = logs ]; then
        COMPREPLY=()
    else
        compopt -o filenames 2> /dev/null
        mapfile -t COMPREPLY < <(compgen -f -- "$cur")
    fi
}
complete -F _kanit kanit
