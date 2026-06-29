#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="$SCRIPT_DIR/busca_videos.conf"
PIRATEBAY_CMD="${PIRATEBAY_CMD:-piratebay}"
PIRATEBAY_TIMEOUT="${PIRATEBAY_TIMEOUT:-15}"

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
    local current_query=""
    local -a current_blacklist=()

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue

        if [[ "$line" =~ ^[[:space:]]*\"(.+)\":[[:space:]]*$ ]]; then
            if [[ -n "$current_query" ]]; then
                do_search "$current_query" "${current_blacklist[@]+"${current_blacklist[@]}"}"
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
        do_search "$current_query" "${current_blacklist[@]+"${current_blacklist[@]}"}"
    fi
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

do_search() {
    local query="$1"
    shift
    local blacklist=("$@")

    echo "Buscando por: \"$query\""

    local raw
    if ! raw=$(run_piratebay search "$query" --json); then
        return
    fi

    if [[ -z "$raw" ]] || ! echo "$raw" | jq empty 2>/dev/null; then
        echo "  ERRO: resposta inválida (não é JSON)." >&2
        return
    fi

    local -a new_titles=()
    local -a new_ids=()
    local -a new_sizes=()
    local -a new_seeds=()
    local -a new_leechers=()

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
    done < <(echo "$raw" | jq -r '.[] | select((.category // .Category // "0") | tonumber? // 0 | . >= 200 and . <= 299) | [ (.id // .Id // ""), ((.name // .Name // .title // .Title // "") | gsub("^\\s+|\\s+$"; "")), (.size // .Size // "N/A"), (.seeders // .Seeders // .seeds // "0"), (.leechers // .Leechers // .leech // "0") ] | @tsv')

    local count=${#new_titles[@]}
    echo "  ${count} resultado(s) novo(s) após filtro"

    if [[ $count -eq 0 ]]; then
        echo "  Nenhum resultado novo."
        return
    fi

    if command -v notify-send &>/dev/null; then
        notify-send -u normal "🏴‍☠️ busca_videos" \
            "${count} resultado(s) novo(s) para \"${query}\"\nAbrindo seleção..."
    fi

    local -a yad_rows=()
    local -a intercalado_dl=()
    for i in "${!new_titles[@]}"; do
        yad_rows+=(TRUE "${new_titles[$i]}" "${new_ids[$i]}")
        intercalado_dl+=("${new_titles[$i]}" "${new_sizes[$i]}" "${new_seeds[$i]}" "${new_leechers[$i]}" "${new_ids[$i]}")
    done

    local selected exit_code
    selected=$(yad \
        --title="🏴‍☠️  busca_videos — \"${query}\"" \
        --text="<b>${count} resultado(s) encontrado(s).</b>\nMarque os que deseja <u>adicionar à blacklist</u> permanentemente." \
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
