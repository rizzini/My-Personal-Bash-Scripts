#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="$SCRIPT_DIR/busca_videos.conf"
PIRATEBAY_CMD="${PIRATEBAY_CMD:-piratebay}"
PIRATEBAY_TIMEOUT="${PIRATEBAY_TIMEOUT:-15}"
PARALLEL_JOBS="${PARALLEL_JOBS:-4}"
FETCH_TMPDIR=""

check_conf() {
    if [[ ! -f "$CONF_FILE" ]]; then
        echo "ERRO: arquivo não encontrado: $CONF_FILE" >&2
        exit 1
    fi
}

convert_units() {
    local bytes=$1
    local value unit
    local suffix=""

    if (( bytes >= 1024*1024*1024 )); then
        value=$(awk "BEGIN { printf \"%.2f\", $bytes/1024/1024/1024 }")
        unit="GB"
    elif (( bytes >= 1024*1024 )); then
        value=$(awk "BEGIN { printf \"%.2f\", $bytes/1024/1024 }")
        unit="MB"

    else
        value=$(awk "BEGIN { printf \"%.2f\", $bytes/1024 }")
        unit="KB"
    fi
    echo "${value}${unit}"
}

add_to_blacklist() {
    local query="$1"
    shift
    local titles=("$@")
    [[ ${#titles[@]} -eq 0 ]] && return

    local -a to_insert=()
    for title in "${titles[@]}"; do
        grep -qxF "$title" "$CONF_FILE" || to_insert+=("$title")
    done
    [[ ${#to_insert[@]} -eq 0 ]] && return

    local tmp
    tmp=$(mktemp)

    if grep -qF "\"${query}\":" "$CONF_FILE"; then
        local titles_file
        titles_file=$(mktemp)
        printf '%s\n' "${to_insert[@]}" > "$titles_file"

        awk -v query="\"${query}\":" -v tfile="$titles_file" '
        $0 == query {
            print
            while ((getline line < tfile) > 0) print line
            close(tfile)
            next
        }
        { print }
        ' "$CONF_FILE" > "$tmp"

        rm -f "$titles_file"
    else
        cp "$CONF_FILE" "$tmp"
        echo "" >> "$tmp"
        echo "\"${query}\":" >> "$tmp"
        printf '%s\n' "${to_insert[@]}" >> "$tmp"
    fi

    mv "$tmp" "$CONF_FILE"
}

parse_and_run() {
    FETCH_TMPDIR=$(mktemp -d)
    trap 'rm -rf "$FETCH_TMPDIR"' EXIT INT TERM

    local -a queries=()
    local -a bl_counts=()
    local -a all_blacklists=()

    local current_query=""
    local -a current_blacklist=()

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue

        if [[ "$line" =~ ^[[:space:]]*\"(.+)\":[[:space:]]*$ ]]; then
            if [[ -n "$current_query" ]]; then
                queries+=("$current_query")
                bl_counts+=("${#current_blacklist[@]}")
                all_blacklists+=("${current_blacklist[@]+"${current_blacklist[@]}"}")
            fi
            current_query="${BASH_REMATCH[1]}"
            current_blacklist=()
        else
            local trimmed="${line#"${line%%[![:space:]]*}"}"
            trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
            [[ -n "$trimmed" ]] && current_blacklist+=("$trimmed")
        fi
    done < "$CONF_FILE"

    if [[ -n "$current_query" ]]; then
        queries+=("$current_query")
        bl_counts+=("${#current_blacklist[@]}")
        all_blacklists+=("${current_blacklist[@]+"${current_blacklist[@]}"}")
    fi

    local total=${#queries[@]}
    [[ $total -eq 0 ]] && return

    local -a pids=()
    local -a slots=()
    local bl_offset=0
    local running=0

    echo "Iniciando $total busca(s) em paralelo (máx ${PARALLEL_JOBS} simultâneas)..."

    for (( i=0; i<total; i++ )); do
        local n_bl="${bl_counts[$i]}"
        local -a bl_slice=()
        if (( n_bl > 0 )); then
            bl_slice=("${all_blacklists[@]:$bl_offset:$n_bl}")
        fi
        bl_offset=$(( bl_offset + n_bl ))

        while (( running >= PARALLEL_JOBS )); do
            local freed=0
            for (( j=0; j<i; j++ )); do
                [[ -z "${pids[$j]:-}" ]] && continue
                if ! kill -0 "${pids[$j]}" 2>/dev/null; then
                    wait "${pids[$j]}" 2>/dev/null || true
                    pids[$j]=""
                    (( running-- )) || true
                    freed=1
                    break
                fi
            done
            (( freed )) || sleep 0.1
        done

        fetch_search "$i" "${queries[$i]}" "${bl_slice[@]+"${bl_slice[@]}"}" &
        pids[$i]=$!
        (( running++ )) || true
    done

    echo "Aguardando conclusão das buscas..."
    for (( i=0; i<total; i++ )); do
        [[ -n "${pids[$i]:-}" ]] && wait "${pids[$i]}" 2>/dev/null || true
    done
    echo "Todas as buscas concluídas. Abrindo resultados..."

    for (( i=0; i<total; i++ )); do
        display_search "$i"
    done
}

abrir_menu_download() {
    local query="$1"
    shift

    local -a dl_rows=()
    while [[ $# -gt 0 ]]; do
        dl_rows+=("$1" "$2" "$3" "$4" "$5")
        shift 5
    done

    local selected_dl exit_dl
    selected_dl=$(yad \
        --title="Download — \"${query}\"" \
        --text="<b>Selecione o item que deseja baixar:</b>\n<i>(Dê duplo clique ou selecione e clique em Baixar)</i>" \
        --list \
        --column="Título" \
        --column="Tamanho" \
        --column="Seeds" \
        --column="Leechers" \
        --column="ID:HD" \
        --width=900 \
        --height=450 \
        --button="Baixar:0" \
        --button="Cancelar:1" \
        --separator="|" \
        "${dl_rows[@]}" 2>/dev/null) && exit_dl=$? || exit_dl=$?

    if [[ $exit_dl -eq 0 ]] && [[ -n "$selected_dl" ]]; then
        local dl_id
        dl_id=$(echo "$selected_dl" | cut -d'|' -f5)
        if [[ -n "$dl_id" ]]; then
            local magnet
            echo "  Refinando link magnet para ID: $dl_id..."
            if ! magnet=$(run_piratebay info "$dl_id" --json | jq -r '.magnet // .magnetLink // .magnet_link // ""'); then
                return
            fi
            if [[ -n "$magnet" ]]; then
                xdg-open "$magnet"
                echo "  Download iniciado para ID $dl_id"
            else
                echo "  ERRO: magnet não encontrado para ID $dl_id" >&2
            fi
        fi
    fi
}

run_piratebay() {
    local output exit_code
    output=$(timeout "$PIRATEBAY_TIMEOUT" "$PIRATEBAY_CMD" "$@" 2>/dev/null)
    exit_code=$?
    if [[ $exit_code -eq 124 ]]; then
        echo "  ERRO: timeout após ${PIRATEBAY_TIMEOUT}s ao executar: $PIRATEBAY_CMD $*" >&2
        return 124
    elif [[ $exit_code -ne 0 ]]; then
        echo "  ERRO: falha ao executar: $PIRATEBAY_CMD $* (código $exit_code)" >&2
        return $exit_code
    fi
    echo "$output"
}

fetch_search() {
    local slot="$1"
    local query="$2"
    shift 2
    local blacklist=("$@")

    local out_raw="$FETCH_TMPDIR/${slot}.raw"
    local out_bl="$FETCH_TMPDIR/${slot}.blacklist"
    local out_query="$FETCH_TMPDIR/${slot}.query"
    local out_err="$FETCH_TMPDIR/${slot}.err"

    printf '%s' "$query" > "$out_query"
    printf '%s\n' "${blacklist[@]+"${blacklist[@]}"}" > "$out_bl"

    echo "Buscando por: \"$query\""

    local raw
    if ! raw=$(run_piratebay search "$query" --json 2>"$out_err"); then
        echo "  ERRO na busca de \"$query\" — veja ${out_err}" >&2
        touch "$FETCH_TMPDIR/${slot}.done"
        return
    fi

    if [[ -z "$raw" ]] || ! echo "$raw" | jq empty 2>/dev/null; then
        echo "  ERRO: resposta inválida para \"$query\" (não é JSON)." >&2
        touch "$FETCH_TMPDIR/${slot}.done"
        return
    fi

    echo "$raw" | jq -r \
        '.[] | select((.category // .Category // "0") | tonumber? // 0 | . >= 200 and . <= 299)
         | [ (.id // .Id // ""),
             ((.name // .Name // .title // .Title // "") | gsub("^\\s+|\\s+$"; "")),
             (.size // .Size // "0"),
             (.seeders // .Seeders // .seeds // "0"),
             (.leechers // .Leechers // .leech // "0") ]
         | @tsv' > "$out_raw"

    touch "$FETCH_TMPDIR/${slot}.done"
}

display_search() {
    local slot="$1"

    local out_raw="$FETCH_TMPDIR/${slot}.raw"
    local out_bl="$FETCH_TMPDIR/${slot}.blacklist"
    local out_query="$FETCH_TMPDIR/${slot}.query"

    local query
    query=$(<"$out_query")

    local -a blacklist=()
    if [[ -s "$out_bl" ]]; then
        while IFS= read -r entry; do
            [[ -n "$entry" ]] && blacklist+=("$entry")
        done < "$out_bl"
    fi

    local -a new_titles=() new_ids=() new_sizes=() new_seeds=() new_leechers=()

    if [[ -s "$out_raw" ]]; then
        while IFS=$'\t' read -r id title size seeds leechers; do
            [[ -z "$title" ]] && continue
            local blocked=0
            for entry in "${blacklist[@]+"${blacklist[@]}"}"; do
                [[ "$title" == $entry ]] && blocked=1 && break
            done
            [[ $blocked -eq 1 ]] && continue

            new_titles+=("$title")
            new_ids+=("$id")
            new_sizes+=("$(convert_units "$size")")
            new_seeds+=("$seeds")
            new_leechers+=("$leechers")
        done < "$out_raw"
    fi

    local count=${#new_titles[@]}
    echo "  \"$query\": ${count} resultado(s) novo(s) após filtro"

    if [[ $count -eq 0 ]]; then
        echo "  Nenhum resultado novo para \"$query\"."
        return
    fi

    local -a yad_rows=() intercalado_dl=()
    for i in "${!new_titles[@]}"; do
        yad_rows+=(TRUE "${new_titles[$i]}" "${new_ids[$i]}")
        intercalado_dl+=("${new_titles[$i]}" "${new_sizes[$i]}" "${new_seeds[$i]}" "${new_leechers[$i]}" "${new_ids[$i]}")
    done

    local selected exit_code
    selected=$(yad \
        --title="busca_videos — \"${query}\"" \
        --text="<b>${count} resultado(s) encontrado(s).</b>\nMarque os que deseja <u>adicionar à blacklist</u>:" \
        --list \
        --checklist \
        --print-all \
        --column="Ignorar" \
        --column="Título" \
        --column="ID:HD" \
        --width=700 \
        --height=400 \
        --button="Escolher para Download:2" \
        --button="Aplicar Blacklist:0" \
        --button="Fechar sem salvar:1" \
        --separator="|" \
        "${yad_rows[@]}" 2>/dev/null) && exit_code=$? || exit_code=$?

    if [[ $exit_code -eq 2 ]]; then
        abrir_menu_download "$query" "${intercalado_dl[@]}"
        return
    fi

    if [[ $exit_code -ne 0 ]]; then
        echo "Fechado sem alterações."
        return
    fi

    if [[ -z "$selected" ]]; then
        echo "Nenhum título marcado."
        return
    fi

    local -a to_blacklist=()
    while IFS='|' read -r checked title _; do
        [[ "$checked" == "TRUE" ]] && [[ -n "$title" ]] && to_blacklist+=("$title")
    done <<< "$selected"

    if [[ ${#to_blacklist[@]} -gt 0 ]]; then
        add_to_blacklist "$query" "${to_blacklist[@]}"
        echo "${#to_blacklist[@]} título(s) adicionado(s) à blacklist de \"${query}\"."
    else
        echo "Nenhum título marcado para blacklist."
    fi
}

check_conf
parse_and_run
