#!/bin/bash

if [ "$EUID" -ne 0 ]; then
    echo "Rode script do Waydroid como root."
    exit 1
fi

waydroid_state() {
    if lsns | grep -E 'android|lineageos' &> /dev/null; then
        return 0
    fi

    if systemctl is-active "waydroid-container.service" &> /dev/null; then
        return 0
    fi

    return 1
}

if [ ! -d "/tmp/waydroid_logs" ]; then
    mkdir -p /tmp/waydroid_logs
fi

if waydroid_state; then
    instance_mode="closing"
else
    instance_mode="openning"
fi

logfile="/tmp/waydroid_logs/${instance_mode}_waydroid_$(date +%H_%M_%S)_$$_$RANDOM.log"
exec > >(tee -a "$logfile") 2>&1
set -x

original_user="${SUDO_USER:-$USER}"
original_user_home="$(getent passwd "$original_user" | cut -d: -f6)"
original_user_id="$(id -u "$original_user")"

run_as_user() {
    sudo -u "$original_user" \
        XDG_RUNTIME_DIR="/run/user/$original_user_id" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$original_user_id/bus" \
        "$@"
}

manage_environment_notifications() {
    local mode="$1"

    notifications_status="$(run_as_user qdbus6 org.freedesktop.Notifications /org/freedesktop/Notifications org.freedesktop.Notifications.Inhibited)"

    if [[ "$mode" == 'disable' ]]; then
        if [[ "$notifications_status" == 'false' ]]; then
            run_as_user qdbus6 org.kde.kglobalaccel /component/plasmashell invokeShortcut "toggle do not disturb"
        fi
    elif [[ "$mode" == 'enable' ]]; then
        if [[ "$notifications_status" == 'true' ]]; then
            run_as_user qdbus6 org.kde.kglobalaccel /component/plasmashell invokeShortcut "toggle do not disturb"
        fi
    fi
}

notify() {
    local message="$1"
    local urgency="$2"

    if [ "$urgency" == critical ]; then
        (
            open_latest_log=$(find /tmp/waydroid_logs -maxdepth 1 -type f -name 'openning_waydroid_*' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)

            action=$(run_as_user systemd-run --user --scope --quiet notify-send -u critical -t 0 "$message" -A "open_log=Abrir log")

            if [[ "$action" == "open_log" ]]; then
                if [[ -n "$open_latest_log" ]]; then
                    run_as_user kate "$open_latest_log"
                fi
            fi
        ) & disown
    else
        run_as_user systemd-run --user --scope --quiet notify-send "$message"
    fi
}

pidfile="/tmp/waydroid_sync.pid"
if [ -f "$pidfile" ]; then
    notify "Sincronização em andamento.."
    exit 1
fi

mem_free_space=0

copy_userdata_to_mem() {
    local aborted=0
    local died=0

    touch "$pidfile"
    if [ "$copy_IMGs" == 'true' ]; then
        rm -f /tmp/system.img

        if [ "$(awk '/\<images_path\>/{print $3}' /var/lib/waydroid/waydroid.cfg)" != '/tmp' ]; then
            sed -i '/\<images_path\>/ s|\(\<images_path\>[[:space:]]*=[[:space:]]*\).*|\1/tmp|' /var/lib/waydroid/waydroid.cfg
        fi

        src="/usr/share/waydroid-extra/images/${container_profile}/system.img"

        size=$(stat -c%s "$src")

        mem_free_space="$(df --output=avail -B1 /tmp | tail -n1)"
        if [ $((size + 200000000)) -gt "$mem_free_space" ]; then
            rm -f /tmp/system.img
            notify "Falta de memória, não foi possível copiar as IMGs." critical
            rm -f "$pidfile"
            exit 1
        fi

        fifo="/tmp/waydroid_progress_fifo_$$"
        mkfifo "$fifo"

        run_as_user yad --progress \
            --title="Waydroid" \
            --center \
            --width=400 \
            --text="Copiando imagens para memória..." \
            --auto-close \
            --skip-taskbar \
            --button="Abortar:1" < "$fifo" &

        yad_pid=$!

        pipe_status_file="/tmp/waydroid_systemimg_pipe_status_$$"

        container_profile_file="/tmp/waydroid_profile_$$"
        echo "$container_profile" > "$container_profile_file"

        setsid bash -c '

        container_profile=$(</tmp/waydroid_profile_*)

        stdbuf -oL rsync -a --progress /usr/share/waydroid-extra/images/"'"${container_profile}"'"/system.img /tmp/

        exit_code=$?

        echo "$exit_code" > "'"$pipe_status_file"'"

        exit "$exit_code"
        ' 2>&1 | stdbuf -oL tr '\r' '\n' | stdbuf -oL awk '
        {
            if (match($0, /([0-9]{1,3})%/, m)) {
                print m[1]
                fflush()
            }
        }
        END {
            print 100
            fflush()
        }
        ' > "$fifo" &

        pipeline_pid=$!

        wait "$yad_pid"
        yad_status=$?

        if [ "$yad_status" -eq 1 ] || [ "$yad_status" -eq 252 ]; then
            aborted=1

            kill -TERM -- -"$pipeline_pid" 2>/dev/null
            wait "$pipeline_pid"
        else
            wait "$pipeline_pid"

            if [ -f "$pipe_status_file" ]; then
                pipe_status="$(cat "$pipe_status_file")"
            else
                pipe_status=1
            fi
        fi

        rm -f "$container_profile_file"
        rm -f "$pipe_status_file"
        rm -f "$fifo"

        if [ "$yad_status" -eq 1 ] || [ "$yad_status" -eq 252 ]; then
            aborted=1
        else
            if [ "$pipe_status" -ne 0 ]; then
                died=1
            fi
        fi

        if [ $aborted -eq 1 ]; then
            rm -f /tmp/system.img
            rm -f "$pidfile"
            exit 10
        fi

        if [ $died -eq 1 ]; then
            notify "Erro ao copiar imagens para memória." critical
            rm -f /tmp/system.img
            rm -f "$pidfile"
            exit 1
        fi

        ln -sf /usr/share/waydroid-extra/images/"${container_profile}"/vendor.img /tmp/

        touch /tmp/waydroid_IMGs_on_mem
    fi

    mem_mount="$(findmnt -no FSTYPE "$original_user_home/.local/share/waydroid")"

    if [[ -e "$original_user_home"/.local/share/WAYDROID_CONTAINERS/"$container_profile"/waydroid_bkp || "$mem_mount" == 'tmpfs' ]]; then
        msg="Erro: "
        exists=""

        if [[ -e "$original_user_home"/.local/share/WAYDROID_CONTAINERS/"$container_profile"/waydroid_bkp ]]; then
            exists+="${original_user_home}/.local/share/WAYDROID_CONTAINERS/${container_profile}/waydroid_bkp"
        fi

        if [[ -e "$original_user_home"/.local/share/WAYDROID_CONTAINERS/"$container_profile"/waydroid_bkp && "$mem_mount" == 'tmpfs' ]]; then
            exists+=", "
        fi

        if [[ "$mem_mount" == 'tmpfs' ]]; then
            exists+="/dev/shm/waydroid"
        fi

        msg+="$exists já existe(m). Remova manualmente com cuidado antes de continuar."
        notify "$msg" critical
        rm -f "$pidfile"
        exit 1
    fi

    src_size=$(du -sb "$original_user_home"/.local/share/waydroid | awk '{print $1}')

    mem_free_space="$(df --output=avail -B1 /tmp | tail -n1)"
    if [ $((src_size + 200000000)) -gt "$mem_free_space" ]; then
        notify "Falta de memória, não foi possível copiar os dados do usuário. Retornar o backup manualmente." critical
        rm -f /tmp/system.img
        rm -f "$pidfile"
        exit 1
    fi

    fifo="/tmp/waydroid_progress_fifo_$$"
    mkfifo "$fifo"

    mkdir -p /dev/shm/waydroid

    run_as_user yad --progress \
        --title="Waydroid" \
        --center \
        --width=400 \
        --text="Copiando dados para a memória..." \
        --skip-taskbar \
        --auto-close \
        --button="Abortar:1" \
        < "$fifo" &

    yad_pid=$!

    pipe_status_file="/tmp/waydroid_pipe_status_$$"

    container_profile_file="/tmp/waydroid_profile_$$"
    echo "$container_profile" > "$container_profile_file"

    setsid bash -c '

    container_profile=$(</tmp/waydroid_profile_*)

    cd "'"$original_user_home"'"/.local/share/WAYDROID_CONTAINERS/"'"$container_profile"'"

    stdbuf -oL rsync -a \
        --numeric-ids \
        --info=progress2 \
        --no-inc-recursive \
        waydroid/ /dev/shm/waydroid/

    echo $? > "'"$pipe_status_file"'"
    ' 2>&1 | tr '\r' '\n' | awk '
    {
        if (match($0, /([0-9]+)%/, m)) {
            print m[1]
            fflush()
        }
    }
    END {
        print 100
    }
    ' > "$fifo" &

    pipe_pid=$!

    aborted=0
    died=0

    wait "$yad_pid"
    yad_status=$?

    if [ "$yad_status" -eq 1 ] || [ "$yad_status" -eq 252 ]; then
        aborted=1

        kill -TERM -- -"$pipe_pid" 2>/dev/null
        wait "$pipe_pid"
    else
        wait "$pipe_pid"

        if [ -f "$pipe_status_file" ]; then
            read -r pipe_status < "$pipe_status_file"
        else
            pipe_status=1
        fi
    fi

    rm -f "$pipe_status_file"
    rm -f "$container_profile_file"
    rm -f "$fifo"

    if [ $aborted -eq 1 ]; then
        if [ -f '/tmp/waydroid_IMGs_on_mem' ]; then
            rm -f /tmp/system.img  /tmp/waydroid_IMGs_on_mem
        fi

        rm -rf /dev/shm/waydroid

        rm -rf "$original_user_home"/.local/share/WAYDROID_CONTAINERS/"$container_profile"/waydroid_bkp
        rm -f "$pidfile"
        exit 10
    fi

    case "${pipe_status:-0}" in
        0) ;;
        *) died=1 ;;
    esac

    if [ $died -eq 1 ]; then
        if [ -f '/tmp/waydroid_IMGs_on_mem' ]; then
            rm -f /tmp/system.img  /tmp/waydroid_IMGs_on_mem
        fi

        rm -rf /dev/shm/waydroid

        rm -rf "$original_user_home"/.local/share/WAYDROID_CONTAINERS/"$container_profile"/waydroid_bkp
        rm -f "$pidfile"

        notify "Erro copiando dados para a memória.."
        exit 1
    fi

    mv "$original_user_home"/.local/share/WAYDROID_CONTAINERS/"$container_profile"/waydroid "$original_user_home"/.local/share/WAYDROID_CONTAINERS/"$container_profile"/waydroid_bkp

    rm -f "$pidfile"
}

copy_userdata_to_disk() {
    touch "$pidfile"

    if [ -f '/tmp/waydroid_IMGs_on_mem' ]; then
        rm -f /tmp/waydroid_IMGs_on_mem
        rm -f /tmp/system.img /tmp/vendor.img
    fi

    umount /dev/shm/waydroid/data/media

    fifo="/tmp/waydroid_progress_fifo_$$"
    mkfifo "$fifo"

    mkdir -p "$original_user_home"/.local/share/waydroid

    run_as_user yad --progress \
        --title="Waydroid" \
        --center \
        --width=400 \
        --text="Retornando dados para o disco..." \
        --auto-close \
        --skip-taskbar \
        --no-buttons \
        < "$fifo" &

    yad_pid=$!

    pipe_status_file="/tmp/waydroid_pipe_status_$$"
    rm -f "$pipe_status_file"

    container_profile_file="/tmp/waydroid_profile_$$"
    echo "$container_profile" > "$container_profile_file"

    setsid bash -c '

    container_profile=$(</tmp/waydroid_profile_*)

    cd /dev/shm

    stdbuf -oL rsync -a --numeric-ids --info=progress2 --no-inc-recursive waydroid/ "'"$original_user_home"'"/.local/share/WAYDROID_CONTAINERS/"'"${container_profile}"'"/waydroid/

    echo $? > "'"$pipe_status_file"'"

    ' 2>&1 | tr '\r' '\n' | awk '{ if (match($0,/([0-9]+)%/,m)){ print m[1]; fflush() } } END{ print 100 }' > "$fifo" &

    pipe_pid=$!

    wait "$pipe_pid"
    wait "$yad_pid"

    if [ -f "$pipe_status_file" ]; then
        read -r pipe_status < "$pipe_status_file"
     else
        pipe_status=1
    fi

    rm -f "$container_profile_file"
    rm -f "$pipe_status_file"
    rm -f "$fifo"

    if [ "$pipe_status" -ne 0 ]; then
        notify "Erro ao copiar arquivos de /dev/shm/waydroid para ${original_user_home}/.local/share/WAYDROID_CONTAINERS/${container_profile}/waydroid" critical
        rm -f "$pidfile"
        exit 1
    fi

    rm -rf /dev/shm/waydroid
    rm -rf "$original_user_home"/.local/share/WAYDROID_CONTAINERS/"$container_profile"/waydroid_bkp
    rm -f "$pidfile"
}

notify_exit() {
    trap 'notify "Waydroid encerrado de forma inesperada." critical; manage_environment_notifications enable' INT TERM
    trap 'notify "Waydroid encerrado."; manage_environment_notifications enable' EXIT
}

cooldown() {
    local cooldown_file="/tmp/waydroid_restart_cooldown"
    local cooldown_seconds=5

    local now
    now=$(date +%s)

    if [ -f "$cooldown_file" ]; then
        local last
        last=$(cat "$cooldown_file")

        if (( now - last < cooldown_seconds )); then
            return 1
        fi
    fi

    echo "$now" > "$cooldown_file"
}

connect_adb() {
    (
        for ((i=0; i<5; i++)); do
            adb_connect="$(adb connect 192.168.240.112)"
            if [[ "$adb_connect" == *"connected to"* || "$adb_connect" == *"already connected"* ]]; then
                break
            fi
            sleep 2
        done
    ) &> /dev/null &

}

cleanup() {
    if mountpoint -q "$original_user_home"/.local/share/waydroid/data/media; then
        for ((i=0; i<5; i++)); do
            if umount "$original_user_home"/.local/share/waydroid/data/media; then
                break
            fi
            sleep 0.2
        done
    fi

    if mountpoint -q "$original_user_home"/.local/share/waydroid; then
        for ((i=0; i<5; i++)); do
            if umount "$original_user_home"/.local/share/waydroid; then
                break
            fi
            sleep 0.2
        done
    fi

    if [[ -f "$container_profile_file" ]]; then
        rm -f "$container_profile_file"
    fi

    if [[ -f "$fifo" ]]; then
        rm -f "$fifo"
    fi

    if [[ -f "$pidfile" ]]; then
        rm -f "$pidfile"
    fi


}

trap cleanup EXIT INT TERM

if waydroid_state; then

    notify 'Fechando Waydroid..'
    run_as_user systemd-run --user --scope waydroid session stop
    systemctl stop waydroid-container.service keyd.service

    if [ "$data_in_mem" = 'true' ]; then
        copy_userdata_to_disk
        data_in_mem='false'
    fi

else
    containers=$(find "$original_user_home/.local/share/WAYDROID_CONTAINERS" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r | tr '\n' '!' | sed 's/!$//')
    result=$(run_as_user yad \
        --title="Waydroid" \
        --height=150 \
        --center \
        --form \
        --field="Container::CB" "$containers" \
        --field="Copiar dados p/ mem::CB" "Não!Dados!Dados + Img" \
        --button="Cancelar:1" \
        --button="OK:0")

    ret=$?

    if [[ "$ret" -eq 1 || "$ret" -eq 2 || "$ret" -eq 252 ]]; then
        exit
    fi

    container_profile=$(echo "$result" | cut -d'|' -f1)
    io_mode=$(echo "$result" | cut -d'|' -f2)

    copy_IMGs='false'
    case "$io_mode" in
        Dados)
            copy_IMGs='false'
            copy_userdata_to_mem
            data_in_mem='true'
            ;;

        'Dados + Img')
            copy_IMGs="true"
            copy_userdata_to_mem
            data_in_mem='true'
            ;;
        Não)
            data_in_mem='false'
            ;;
    esac

    pkill -9 adb

    systemctl stop waydroid-container.service

    sed -i 's|^images_path *=.*|images_path = /usr/share/waydroid-extra/images/'"$container_profile"'/|' /var/lib/waydroid/waydroid.cfg

    umount "$original_user_home"/.local/share/waydroid/data/media 2>/dev/null

    umount "$original_user_home"/.local/share/waydroid 2>/dev/null

    if [[ "$io_mode" == 'Não' ]]; then
        if mount --bind "$original_user_home"/.local/share/WAYDROID_CONTAINERS/"$container_profile"/waydroid  "$original_user_home"/.local/share/waydroid; then
            if mount --bind "$original_user_home"/.local/share/WAYDROID_CONTAINERS/"$container_profile"/waydroid_media  "$original_user_home"/.local/share/waydroid/data/media; then
                notify_exit
                systemctl start waydroid-container.service keyd.service
                while IFS= read -r process; do
                    if [[ $process == *"Android with user 0 is ready"* ]]; then
                        manage_environment_notifications disable
                        connect_adb
                    elif [[ $process == *"Did not receive a reply"* ]]; then
                        if cooldown; then
                            notify 'Waydroid travou.. Tentando fechar.' critical
                            bash "$(realpath "$0")" &> /dev/null & disown
                            break
                        fi
                    elif [[ "$process" == *"RuntimeError"* ]]; then
                        notify "Processo do Waydroid apresentou erro na execução." critical
                        exit 1
                    fi
                done < <(run_as_user systemd-run --user --scope waydroid show-full-ui 2>&1)
            else
                notify "Waydroid não rodou; Pasta de media não montada no disco." critical
                exit 1
            fi
        else
            notify "Waydroid não rodou; Pasta de dados não montada no disco." critical
            exit 1
        fi
    else
        if mount --bind /dev/shm/waydroid  "$original_user_home"/.local/share/waydroid; then
            if mount --bind "$original_user_home"/.local/share/WAYDROID_CONTAINERS/"$container_profile"/waydroid_media  /dev/shm/waydroid/data/media; then
                if [ "$copy_IMGs" == 'true' ]; then
                    if [ -f "/tmp/waydroid_IMGs_on_mem" ]; then
                        notify_exit
                        systemctl start waydroid-container.service keyd.service
                        while IFS= read -r process; do
                            if [[ $process == *"Android with user 0 is ready"* ]]; then
                                manage_environment_notifications disable
                                connect_adb
                            elif [[ $process == *"Did not receive a reply"* ]]; then
                                if cooldown; then
                                    notify 'Waydroid travou.. Tentando fechar.' critical
                                    bash "$(realpath "$0")" &> /dev/null & disown
                                    break
                                fi
                            elif [[ "$process" == *"RuntimeError"* ]]; then
                                notify "Processo do Waydroid apresentou erro na execução." critical
                                exit 1
                            fi
                        done < <(run_as_user systemd-run --user --scope waydroid show-full-ui 2>&1)
                    fi
                else
                    notify_exit
                    systemctl start waydroid-container.service keyd.service
                    while IFS= read -r process; do
                        if [[ $process == *"Android with user 0 is ready"* ]]; then
                            manage_environment_notifications disable
                            connect_adb
                        elif [[ $process == *"Did not receive a reply"* ]]; then
                            if cooldown; then
                                notify 'Waydroid travou.. Tentando fechar.' critical
                                bash "$(realpath "$0")" &> /dev/null & disown
                                break
                            fi
                        fi
                    done < <(run_as_user systemd-run --user --scope waydroid show-full-ui 2>&1)
                fi
            else
                notify "Waydroid não rodou; Pasta de media não montada na memória." critical
                exit
            fi
        else
            notify "Waydroid não rodou; Pasta de dados não montada na memória." critical
            exit 1
        fi
    fi

    manage_environment_notifications enable
    run_as_user systemd-run --user --scope waydroid session stop
    systemctl stop waydroid-container.service keyd.service

    if [ "$data_in_mem" = 'true' ]; then
        copy_userdata_to_disk
        data_in_mem='false'
    fi
fi
