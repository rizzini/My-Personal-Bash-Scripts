#!/bin/bash

if [ ! -d "/tmp/waydroid_logs" ]; then
    mkdir -p /tmp/waydroid_logs
fi

logfile="/tmp/waydroid_logs/waydroid_personal_script_log_$(date +%H_%M_%S)_$$_$RANDOM.log"
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

notify() {
    if [ "$2" == critical ]; then
        run_as_user systemd-run --user --scope notify-send -u critical "$1"
    elif [ -z "$2" ]; then
        run_as_user systemd-run --user --scope notify-send "$1"
    fi
}

if [ "$EUID" -ne 0 ]; then
    echo "Rodar como root."
    notify "Rodar como root." critical
    exit 1
fi

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

        echo '@@DEBUG@@'
        grep images_path /var/lib/waydroid/waydroid.cfg #debug

        src="/usr/share/waydroid-extra/images/system.img"

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
        rm -f "$pipe_status_file"

        setsid bash -c '
        stdbuf -oL rsync -a --progress \
            /usr/share/waydroid-extra/images/system.img \
            /tmp/
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

        rm -f "$pipe_status_file"
        rm -f "$fifo"

        printf '%s\n' "${pipe_status[@]}" > /tmp/waydroid_pipe_status

        if [ "$yad_status" -eq 1 ] || [ "$yad_status" -eq 252 ]; then
            aborted=1
        else
            for pipe_exit_code in "${pipe_status[@]}"; do
                if [ "$pipe_exit_code" -ne 0 ]; then
                    died=1
                fi
            done
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

        ln -sf /usr/share/waydroid-extra/images/vendor.img /tmp/

        touch /tmp/waydroid_IMGs_on_mem
    fi

    if [[ -e "$original_user_home"/.local/share/waydroid_bkp || -e /dev/shm/waydroid ]]; then
        msg="Erro: "
        exists=""

        if [[ -e "$original_user_home"/.local/share/waydroid_bkp ]]; then
            exists+="$original_user_home/.local/share/waydroid_bkp"
        fi

        if [[ -e "$original_user_home"/.local/share/waydroid_bkp && -e /dev/shm/waydroid ]]; then
            exists+=", "
        fi

        if [[ -e /dev/shm/waydroid ]]; then
            exists+="/dev/shm/waydroid"
        fi

        msg+="$exists já existe(m). Remova manualmente com cuidado antes de continuar."
        notify "$msg" critical
        rm -f "$pidfile"
        exit 1
    fi

    if ! umount "$original_user_home"/.local/share/waydroid/data/media; then
        notify "Pasta de media ainda montado. Saindo.." critical
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
    rm -f "$pipe_status_file"

    setsid bash -c '

    cd "'"$original_user_home"'"/.local/share

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
    rm -f "$fifo"

    if [ $aborted -eq 1 ]; then
        if [ -f '/tmp/waydroid_IMGs_on_mem' ]; then
            rm -f /tmp/system.img  /tmp/waydroid_IMGs_on_mem
        fi

        rm -rf /dev/shm/waydroid

        mount --bind "$original_user_home"/.local/share/waydroid_media "$original_user_home"/.local/share/waydroid/data/media

        rm -rf "$original_user_home"/.local/share/waydroid_bkp
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

        mount --bind "$original_user_home"/.local/share/waydroid_media \
            "$original_user_home"/.local/share/waydroid/data/media

        rm -rf "$original_user_home"/.local/share/waydroid_bkp
        rm -f "$pidfile"

        notify "Erro copiando dados para a memória.."
        exit 1
    fi

    mv "$original_user_home"/.local/share/waydroid "$original_user_home"/.local/share/waydroid_bkp

    ln -s /dev/shm/waydroid "$original_user_home"/.local/share/waydroid

    mkdir -p /dev/shm/waydroid/data/media

    if ! mount --bind "$original_user_home"/.local/share/waydroid_media /dev/shm/waydroid/data/media; then
        notify "Erro ao montar bind (memória)" critical
        rm -f "$pidfile"
        exit 1
    fi

    if ! mountpoint -q /dev/shm/waydroid/data/media; then
        notify "Bind na memória não foi aplicado corretamente"
        rm -f "$pidfile"
        exit 1
    fi
    rm -f "$pidfile"
}

copy_userdata_to_disk() {
    touch "$pidfile"

    if [ "$(awk '/\<images_path\>/{print $3}' /var/lib/waydroid/waydroid.cfg)" != '/usr/share/waydroid-extra/images' ]; then
        sed -i '/\<images_path\>/ s|\(\<images_path\>[[:space:]]*=[[:space:]]*\).*|\1/usr/share/waydroid-extra/images|' /var/lib/waydroid/waydroid.cfg
    fi

    grep images_path /var/lib/waydroid/waydroid.cfg #debug

    if [ -f '/tmp/waydroid_IMGs_on_mem' ]; then
        rm -f /tmp/waydroid_IMGs_on_mem
        rm -f /tmp/system.img /tmp/vendor.img
    fi

    umount /dev/shm/waydroid/data/media

    if [ -L "$original_user_home/.local/share/waydroid" ]; then
        rm -f "$original_user_home"/.local/share/waydroid
    else
        notify "Erro na restauração! Verifique manualmente. Dados ainda na memória." critical
        rm -f "$pidfile"
        exit 1
    fi

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

    setsid bash -c 'cd /dev/shm; stdbuf -oL rsync -a --numeric-ids --info=progress2 --no-inc-recursive waydroid/ "'"$original_user_home"'"/.local/share/waydroid/' 2>&1 | tr '\r' '\n' | awk '{ if (match($0,/([0-9]+)%/,m)){ print m[1]; fflush() } } END{ print 100 }' > "$fifo" &

    pipe_pid=$!

    wait "$pipe_pid"
    pipe_status=$?

    wait "$yad_pid"

    rm -f "$fifo"

    if [ "$pipe_status" -ne 0 ]; then
        notify "Erro ao copiar arquivos de /dev/shm/waydroid para $original_user_home/.local/share/waydroid" critical
        rm -f "$pidfile"
        exit 1
    fi

    mkdir -p "$original_user_home"/.local/share/waydroid/data/media

    if ! mount --bind "$original_user_home"/.local/share/waydroid_media "$original_user_home"/.local/share/waydroid/data/media; then
        notify "Erro ao montar bind" critical
        rm -f "$pidfile"
        exit 1
    fi

    if ! mountpoint -q "$original_user_home"/.local/share/waydroid/data/media; then
        notify "Bind não foi aplicado corretamente" critical
        rm -f "$pidfile"
        exit 1
    fi

    rm -rf /dev/shm/waydroid
    rm -rf "$original_user_home"/.local/share/waydroid_bkp
    rm -f "$pidfile"
}

notify_exit() {
    trap 'notify "Waydroid encerrado de forma inesperada." critical' INT TERM
    trap 'notify "Waydroid encerrado."' EXIT
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

waydroid_state() {
    if lsns | grep -E 'android|lineageos' &> /dev/null; then
        return 0
    fi

    if systemctl is-active "waydroid-container.service" &> /dev/null; then
        return 0
    fi

    #slow AF
    if [ "$(waydroid shell getprop sys.boot_completed 2>/dev/null)" = "1" ]; then
        return 0
    fi

    return 1
}

if waydroid_state; then

    notify 'Fechando Waydroid..'
    run_as_user systemd-run --user --scope waydroid session stop
    systemctl stop waydroid-container.service keyd.service

    if [ "$data_in_mem" = 'true' ]; then
        copy_userdata_to_disk
        data_in_mem="false"
    fi

else
    choice=$(run_as_user yad --title="Waydroid" \
        --center \
        --question \
        --text="Copiar dados para a memória?" \
        --button=Não:1 \
        --button=Sim:0 \
        --button='Sim + IMGs':3 \
        --button=Cancelar:2)

    choice=$?

    copy_IMGs="false"
    case "$choice" in
        0)
            copy_IMGs="false"
            copy_userdata_to_mem
            data_in_mem=true
            ;;

        3)
            copy_IMGs="true"
            copy_userdata_to_mem
            data_in_mem="true"
            ;;

        2|252)
            exit
            ;;

        1)
            data_in_mem="false"
            ;;
    esac

    systemctl restart waydroid-container.service keyd.service

    pkill -9 adb

    if [ "$choice" -eq 1 ]; then
        if mountpoint -q "$original_user_home/.local/share/waydroid/data/media"; then
            notify_exit
            while IFS= read -r process; do
                if [[ $process == *"Android with user 0 is ready"* ]]; then
                    connect_adb
                elif [[ $process == *"Did not receive a reply"* ]]; then
                    if cooldown; then
                        notify 'Waydroid travou.. Tentando fechar.' critical
                        bash "$(realpath "$0")" &> /dev/null & disown
                        break
                    fi
                fi
            done < <(run_as_user systemd-run --user --scope waydroid show-full-ui 2>&1)
        else
            notify "Waydroid não rodou; bind do diretório de mídia não está ativo." critical
            exit 1
        fi
    else
        if mountpoint -q /dev/shm/waydroid/data/media; then
            if [ "$copy_IMGs" == 'true' ]; then
                if [ -f "/tmp/waydroid_IMGs_on_mem" ]; then
                    notify_exit
                    while IFS= read -r process; do
                        if [[ $process == *"Android with user 0 is ready"* ]]; then
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
                notify_exit
                while IFS= read -r process; do
                    if [[ $process == *"Android with user 0 is ready"* ]]; then
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
            notify "Waydroid não rodou; dados não estão na memória ou houve algum problema na cópia." critical
            exit 1
        fi
    fi

    run_as_user systemd-run --user --scope waydroid session stop
    systemctl stop waydroid-container.service keyd.service

    if [ "$data_in_mem" = 'true' ]; then
        copy_userdata_to_disk
        data_in_mem='false'
    fi
fi
