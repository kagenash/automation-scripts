#!/bin/bash

# ==============================================================================
# SCRIPT DE RECUPERAÇÃO DE CHOQUE - POSTGRESQL (PDV BRIDGE)
# Versão: 5.4 - SHOCK RECOVERY KAMIKAZE (Zero Tolerância a Downtime)
# Autor: João Victor Pires Pinheiro de Lima
#
# CONTEXTO DE NEGÓCIO (LEIA ANTES DE MODIFICAR):
#   O banco local deste PDV é espelhado segundo a segundo para a central RD.
#   NENHUMA VENDA É PERDIDA se o banco for reiniciado de forma bruta ou se
#   dados não-commitados localmente forem dropados via pg_resetwal.
#   O único risco real é o PDV ficar parado. A prioridade é liberar a porta
#   5432 em segundos. Este script tem carta branca para ser DESTRUTIVO com
#   o estado atual de processos e locks locais.
#
# Requisitos: Ubuntu | PostgreSQL via apt | Sem instalações adicionais
# Log: /var/log/pg_emergency_recovery.log
# ==============================================================================

LOG_FILE="/var/log/pg_emergency_recovery.log"
GRACEFUL_STOP_TIMEOUT=2   # 2s — se não desceu, kill -9 imediato
OVERALL_STATUS=0

# --- Cores para terminal ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

# --- Funções de Logging ---
log() {
    local level="$1" message="$2"
    local timestamp; timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local line="[$timestamp] [$level] $message"
    echo "$line" >> "$LOG_FILE"
    case "$level" in
        "OK   ") echo -e "${GREEN}${line}${NC}" ;;
        "WARN ") echo -e "${YELLOW}${line}${NC}" ;;
        "ERROR") echo -e "${RED}${line}${NC}" ;;
        "DIAG ") echo -e "${CYAN}${line}${NC}" ;;
        "FIX  ") echo -e "${BLUE}${line}${NC}" ;;
        *) echo "$line" ;;
    esac
}
log_info()  { log "INFO " "$1"; }
log_ok()    { log "OK   " "$1"; }
log_warn()  { log "WARN " "$1"; }
log_error() { log "ERROR" "$1"; }
log_fix()   { log "FIX  " "$1"; }
log_sep() {
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    local line; line="[$ts] [-----] $(printf '=%.0s' {1..60})"
    echo "$line" >> "$LOG_FILE"
    echo -e "${BOLD}${line}${NC}"
}
log_blank() { echo "" | tee -a "$LOG_FILE"; }

# ------------------------------------------------------------------------------
# Compatibilidade: dmesg --time-format não existe em util-linux < 2.24.
# ------------------------------------------------------------------------------
_dmesg() { dmesg --time-format iso 2>/dev/null || dmesg 2>/dev/null; }

# ------------------------------------------------------------------------------
# Compatibilidade: df --output= exige coreutils >= 8.21 (Debian 8+).
# ------------------------------------------------------------------------------
_df_output() {
    if df --output=source,size,used,avail,pcent,target / >/dev/null 2>&1; then
        df -h --output=source,size,used,avail,pcent,target 2>/dev/null \
            | tail -n +2 | grep -v "tmpfs\|udev\|overlay\|squashfs"
    else
        df -h 2>/dev/null | tail -n +2 \
            | grep -v "tmpfs\|udev\|overlay\|squashfs" \
            | awk '{print $1, $2, $3, $4, $5, $6}'
    fi
}

# ------------------------------------------------------------------------------
# _nuke_pid <pid> <descrição>
# Kill imediato: sem aviso, sem espera, kill -9 direto.
# ------------------------------------------------------------------------------
_nuke_pid() {
    local pid="$1" descr="$2"
    kill -0 "$pid" 2>/dev/null || { log_info "  PID=$pid ($descr) já não existe."; return 0; }
    log_fix "  KILL -9 PID=$pid ($descr)..."
    kill -9 "$pid" 2>/dev/null
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
        log_error "  PID=$pid sobreviveu ao KILL -9 (processo kernel/zumbi)."
        return 1
    fi
    log_ok "  PID=$pid eliminado."
    return 0
}

# ------------------------------------------------------------------------------
# _nuke_port_5432
# Mata TODA a árvore de processos pendurada na porta 5432, sem exceção.
# ------------------------------------------------------------------------------
_nuke_port_5432() {
    local pids=""
    if command -v ss >/dev/null 2>&1; then
        pids=$(ss -tlnp 2>/dev/null | grep ':5432 ' | grep -oE 'pid=[0-9]+' | cut -d= -f2)
    elif command -v netstat >/dev/null 2>&1; then
        pids=$(netstat -tlnp 2>/dev/null | grep ':5432 ' | awk '{print $7}' | cut -d/ -f1 | grep -oE '[0-9]+')
    fi
    if [ -n "$pids" ]; then
        for pid in $pids; do
            local pname; pname=$(ps -p "$pid" -o comm= 2>/dev/null || echo "?")
            log_fix "  Eliminando PID=$pid ($pname) que ocupa a porta 5432..."
            # Mata filhos primeiro, depois o pai
            pkill -9 -P "$pid" 2>/dev/null
            kill -9 "$pid" 2>/dev/null
        done
        sleep 1
        log_ok "  Porta 5432 limpa."
    else
        log_info "  Porta 5432 já estava livre."
    fi
}

# ------------------------------------------------------------------------------
# _kamikaze_cleanup <data_dir> <port>
# Remove INCONDICIONALMENTE todo lixo de lock/pid/socket do cluster.
# Recria /var/run/postgresql com permissões corretas.
# ------------------------------------------------------------------------------
_kamikaze_cleanup() {
    local data_dir="$1" port="$2"
    log_fix "  Limpeza kamikaze de locks, PID files e sockets..."
    # PID file
    rm -f "${data_dir}/postmaster.pid" 2>/dev/null
    # Sockets e locks do cluster
    rm -f "/var/run/postgresql/.s.PGSQL.${port}"       2>/dev/null
    rm -f "/var/run/postgresql/.s.PGSQL.${port}.lock"  2>/dev/null
    # Qualquer outro arquivo de lock residual do postgres
    rm -f /var/run/postgresql/.s.PGSQL.* 2>/dev/null
    # Recria o diretório com permissões corretas
    mkdir -p /var/run/postgresql
    chown postgres:postgres /var/run/postgresql
    chmod 2775 /var/run/postgresql
    log_ok "  Limpeza kamikaze concluída."
}

# ==============================================================================
# PRÉ-REQUISITOS
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
    echo "ERRO: Este script precisa de privilégios de administrador."
    echo "Execute com: sudo $0"
    exit 1
fi

if [ ! -f "$LOG_FILE" ]; then
    install -m 640 /dev/null "$LOG_FILE" 2>/dev/null || \
        { echo "ERRO: Não foi possível criar $LOG_FILE"; exit 1; }
else
    chmod 640 "$LOG_FILE" 2>/dev/null
fi

log_sep
log_info "INICIANDO SHOCK RECOVERY POSTGRESQL v5.4"
log_info "Executado por: $(who am i 2>/dev/null || echo 'root direto')"
log_info "Hostname : $(hostname 2>/dev/null)"
log_info "Kernel   : $(uname -r)"
log_info "OS       : $(lsb_release -ds 2>/dev/null || grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')"
log_sep

if ! command -v pg_lsclusters >/dev/null 2>&1; then
    log_error "pg_lsclusters não encontrado. PostgreSQL não está instalado via apt."
    exit 1
fi

# ==============================================================================
# FASE 1 — DIAGNÓSTICO SISTÊMICO
# ==============================================================================

log_blank
log_sep
log_info "FASE 1: DIAGNÓSTICO SISTÊMICO"
log_sep

SYSTEM_ISSUES=()

# ------------------------------------------------------------------------------
# [DIAG 1/7] Espaço em disco e inodes
# ------------------------------------------------------------------------------
log_info "[DIAG 1/7] Espaço em disco e inodes..."

while IFS= read -r dfline; do
    mountpoint=$(echo "$dfline" | awk '{print $6}')
    usage=$(echo "$dfline" | awk '{print $5}' | tr -d '%')
    avail=$(echo "$dfline" | awk '{print $4}')
    if [ "$usage" -ge 95 ] 2>/dev/null; then
        log_error "DISCO CRÍTICO: $mountpoint — ${usage}% usado (${avail} livres)."
        SYSTEM_ISSUES+=("DISK_FULL:$mountpoint")
    elif [ "$usage" -ge 85 ] 2>/dev/null; then
        log_warn "DISCO ALTO: $mountpoint — ${usage}% usado."
    else
        log_ok "Disco $mountpoint: ${usage}% usado (${avail} livres)."
    fi
done < <(_df_output)

while IFS= read -r inode_line; do
    mountpoint=$(echo "$inode_line" | awk '{print $6}')
    inode_usage=$(echo "$inode_line" | awk '{print $5}' | tr -d '%')
    if [ "$inode_usage" -ge 90 ] 2>/dev/null; then
        log_error "INODES CRÍTICOS: $mountpoint — ${inode_usage}% usados."
        SYSTEM_ISSUES+=("INODES_FULL:$mountpoint")
    fi
done < <(df -i 2>/dev/null | tail -n +2 | grep -v "tmpfs\|udev")

# ------------------------------------------------------------------------------
# [DIAG 1b] Filesystems montados em modo somente leitura
#
# EXT4 com a opção errors=remount-ro (padrão Ubuntu) remonta o FS como RO
# ao detectar erros de disco. Quando isso acontece o PostgreSQL não consegue
# escrever absolutamente nada — WAL, PID file, sockets — e falha silenciosamente.
# Filtra apenas dispositivos reais (/dev/*); exclui todos os FS virtuais.
# ------------------------------------------------------------------------------
log_info "[DIAG 1b] Filesystems em modo somente leitura..."

while IFS=" " read -r ro_dev ro_mp _rest; do
    log_error "Filesystem SOMENTE LEITURA: $ro_dev montado em $ro_mp"
    SYSTEM_ISSUES+=("READONLY_FS:${ro_dev}:${ro_mp}")
done < <(awk '$1 ~ /^\/dev\// && $4 ~ /(^|,)ro(,|$)/' /proc/mounts 2>/dev/null)

if ! grep -q "^READONLY_FS" <(printf '%s\n' "${SYSTEM_ISSUES[@]}") 2>/dev/null; then
    log_ok "Nenhum filesystem real montado em modo somente leitura."
fi

# ------------------------------------------------------------------------------
# [DIAG 2/7] Porta 5432
# ------------------------------------------------------------------------------
log_info "[DIAG 2/7] Processos ocupando a porta 5432..."

PORT_PIDS=""
if command -v ss >/dev/null 2>&1; then
    # sort -u: ss lista o mesmo PID para IPv4 e IPv6 — deduplica
    PORT_PIDS=$(ss -tlnp 2>/dev/null | grep ':5432 ' | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)
elif command -v netstat >/dev/null 2>&1; then
    PORT_PIDS=$(netstat -tlnp 2>/dev/null | grep ':5432 ' | awk '{print $7}' | cut -d/ -f1 | grep -oE '[0-9]+' | sort -u)
fi

if [ -n "$PORT_PIDS" ]; then
    for pid in $PORT_PIDS; do
        proc_name=$(ps -p "$pid" -o comm= 2>/dev/null || echo "desconhecido")
        log_warn "Porta 5432 ocupada por: $proc_name (PID=$pid)"
        if echo "$proc_name" | grep -qi "postgres"; then
            log_info "  PostgreSQL residual — será eliminado no loop de clusters."
        else
            log_error "  Processo não-PostgreSQL na porta 5432: $proc_name (PID=$pid)"
            SYSTEM_ISSUES+=("PORT_CONFLICT:$pid:$proc_name")
        fi
    done
else
    log_ok "Porta 5432 livre."
fi

# ------------------------------------------------------------------------------
# [DIAG 3/7] OOM Killer
# ------------------------------------------------------------------------------
log_info "[DIAG 3/7] OOM Killer..."

oom_hits=$(_dmesg | grep -i "oom\|out of memory\|killed process" | tail -20)
if [ -n "$oom_hits" ]; then
    log_warn "OOM Killer detectado:"
    echo "$oom_hits" | while IFS= read -r l; do log_warn "  OOM >> $l"; done
    echo "$oom_hits" | grep -qi "postgres" && {
        log_error "OOM Killer MATOU processo PostgreSQL!"
        SYSTEM_ISSUES+=("OOM_KILLED_POSTGRES")
    }
else
    log_ok "Nenhum OOM Killer detectado."
fi

mem_total=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
mem_avail=$(grep MemAvailable /proc/meminfo 2>/dev/null | awk '{print $2}')
if [ -n "$mem_total" ] && [ -n "$mem_avail" ]; then
    mem_used_pct=$(( (mem_total - mem_avail) * 100 / mem_total ))
    log_info "RAM: ${mem_used_pct}% em uso — $(( mem_avail / 1024 )) MB livres de $(( mem_total / 1024 )) MB."
    [ "$mem_used_pct" -ge 90 ] && {
        log_warn "Memória crítica (${mem_used_pct}%)."
        SYSTEM_ISSUES+=("LOW_MEMORY")
    }
fi

swap_total=$(grep SwapTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
swap_free=$(grep SwapFree /proc/meminfo  2>/dev/null | awk '{print $2}')
if [ -n "$swap_total" ] && [ "$swap_total" -gt 0 ]; then
    swap_pct=$(( (swap_total - swap_free) * 100 / swap_total ))
    log_info "Swap: ${swap_pct}% em uso ($(( swap_free / 1024 )) MB livres)."
    [ "$swap_pct" -ge 80 ] && log_warn "Swap alto (${swap_pct}%)."
else
    log_warn "Sem swap configurado."
fi

# ------------------------------------------------------------------------------
# [DIAG 4/7] CrowdStrike Falcon / AppArmor / SELinux
# ------------------------------------------------------------------------------
log_info "[DIAG 4/7] CrowdStrike Falcon / AppArmor / SELinux..."

FALCON_CTL=""
for fp in /opt/CrowdStrike/falconctl /opt/crowdstrike/falconctl; do
    [ -x "$fp" ] && FALCON_CTL="$fp" && break
done

if systemctl is-active --quiet falcon-sensor 2>/dev/null; then
    log_warn "CrowdStrike Falcon ATIVO nesta máquina."
    if [ -n "$FALCON_CTL" ]; then
        rfm_state=$("$FALCON_CTL" -g --rfm-state 2>/dev/null | awk -F'=' '{print $2}' | tr -d ' ')
        rfm_reason=$("$FALCON_CTL" -g --rfm-reason 2>/dev/null | awk -F'=' '{print $2}' | tr -d ' ')
        if [ "$rfm_state" = "true" ] || [ "$rfm_state" = "1" ]; then
            log_ok "  Falcon em RFM — prevenção DESABILITADA (motivo: ${rfm_reason:-sem conectividade})."
        else
            log_warn "  Falcon FORA do RFM — políticas de prevenção ATIVAS."
            log_warn "  AID: $("$FALCON_CTL" -g --aid 2>/dev/null | awk -F'=' '{print $2}' | tr -d ' ')"
            log_warn "  Se o Postgres não subir após este script, contate TI para exclusão do binário."
            # Não adiciona a SYSTEM_ISSUES: CrowdStrike raramente é a causa real do problema.
            # O script continua a recuperação normalmente.
        fi
    else
        log_warn "  falconctl não encontrado. Estado RFM desconhecido."
        # Idem: não bloqueia o fluxo de recuperação.
    fi
elif systemctl list-unit-files 2>/dev/null | grep -qF "falcon-sensor.service"; then
    log_info "Falcon instalado mas INATIVO."
else
    log_ok "CrowdStrike não detectado."
    if command -v aa-status >/dev/null 2>&1 && aa-status --enabled >/dev/null 2>&1; then
        log_info "AppArmor ativo."
        if aa-status 2>/dev/null | grep "enforce" | grep -qi "postgres"; then
            log_error "AppArmor ENFORCE para PostgreSQL!"
            SYSTEM_ISSUES+=("APPARMOR_ENFORCE")
        else
            log_ok "Nenhum perfil AppArmor enforce para PostgreSQL."
        fi
    elif command -v getenforce >/dev/null 2>&1; then
        selinux_status=$(getenforce 2>/dev/null)
        log_info "SELinux: $selinux_status"
    else
        log_ok "Nenhum módulo de segurança detectado."
    fi
fi

# ------------------------------------------------------------------------------
# [DIAG 5/7] Memória compartilhada do kernel
# ------------------------------------------------------------------------------
log_info "[DIAG 5/7] Parâmetros de memória compartilhada..."

shmmax=$(cat /proc/sys/kernel/shmmax 2>/dev/null || echo 0)
shmall=$(cat /proc/sys/kernel/shmall 2>/dev/null || echo 0)
page_size=$(getconf PAGE_SIZE 2>/dev/null || echo 4096)
# Usa awk — valores padrão do Linux 64-bit (ex: ULONG_MAX = 18446744073709551615)
# excedem o inteiro com sinal do bash (2^63-1) e causam overflow/erro aritmético.
shmmax_mb=$(awk -v v="$shmmax" 'BEGIN { x=v/1048576; printf (x>999999||x<0) ? "ilimitado" : "%d", x }')
shmall_mb=$(awk -v s="$shmall" -v p="$page_size" \
            'BEGIN { x=s*p/1048576; printf (x>999999||x<0) ? "ilimitado" : "%d", x }')
log_info "kernel.shmmax: ${shmmax_mb} MB | kernel.shmall: ${shmall_mb} MB"
# Compara via awk — seguro para valores > 2^63
if awk -v v="$shmmax" 'BEGIN { exit (v > 0 && v < 134217728) ? 0 : 1 }'; then
    log_warn "kernel.shmmax abaixo de 128MB."
    SYSTEM_ISSUES+=("LOW_SHMMAX")
fi

# ------------------------------------------------------------------------------
# [DIAG 6/7] Socket dir
# ------------------------------------------------------------------------------
log_info "[DIAG 6/7] Diretório de socket Unix..."

PG_SOCKET_DIR="/var/run/postgresql"
if [ -d "$PG_SOCKET_DIR" ]; then
    socket_owner=$(stat -c '%U:%G' "$PG_SOCKET_DIR" 2>/dev/null)
    socket_perms=$(stat -c '%a'  "$PG_SOCKET_DIR" 2>/dev/null)
    log_info "Socket dir: $PG_SOCKET_DIR | Owner: $socket_owner | Perms: $socket_perms"
    [ "$socket_owner" != "postgres:postgres" ] && [ "$socket_owner" != "root:postgres" ] && {
        log_warn "Owner incorreto: '$socket_owner'."
        SYSTEM_ISSUES+=("SOCKET_PERMS")
    }
    stale=$(find "$PG_SOCKET_DIR" -name ".s.PGSQL.*" 2>/dev/null)
    [ -n "$stale" ] && {
        log_warn "Sockets residuais: $stale"
        SYSTEM_ISSUES+=("STALE_SOCKETS")
    } || log_ok "Nenhum socket residual."
else
    log_warn "$PG_SOCKET_DIR não existe — será criado na inicialização."
fi

# ------------------------------------------------------------------------------
# [DIAG 7/7] Logs de sistema
# ------------------------------------------------------------------------------
log_info "[DIAG 7/7] Erros críticos nos logs de sistema..."

if command -v journalctl >/dev/null 2>&1; then
    # Filtra linhas de cabeçalho do journalctl ("-- Logs begin...", "-- No entries --")
    # que sempre aparecem mesmo quando não há entradas e causam falso positivo.
    recent_errors=$(journalctl -u "postgresql*" --since "1 hour ago" --no-pager -p err 2>/dev/null \
        | grep -v '^--' | grep -v '^[[:space:]]*$' | tail -20)
    [ -n "$recent_errors" ] && {
        log_warn "Erros PostgreSQL no journal (última hora):"
        echo "$recent_errors" | while IFS= read -r l; do log_warn "  JOURNAL >> $l"; done
    } || log_ok "Nenhum erro crítico no journal na última hora."
fi

kernel_io_errors=$(_dmesg \
    | grep -iE "ext4|xfs|btrfs|io error|hardware error|disk|sda|nvme|mmc" \
    | grep -iE "error|critical|alert|emerg|fail" \
    | tail -10)
[ -n "$kernel_io_errors" ] && {
    log_error "ERROS DE I/O no kernel — possível falha de hardware:"
    echo "$kernel_io_errors" | while IFS= read -r l; do log_error "  KERNEL >> $l"; done
    SYSTEM_ISSUES+=("IO_ERRORS")
}

# --- Resumo Fase 1 ---
log_blank; log_sep
if [ ${#SYSTEM_ISSUES[@]} -eq 0 ]; then
    log_ok "DIAGNÓSTICO SISTÊMICO: Nenhum problema detectado."
else
    log_warn "DIAGNÓSTICO SISTÊMICO: ${#SYSTEM_ISSUES[@]} problema(s):"
    for i in "${SYSTEM_ISSUES[@]}"; do log_warn "  -> $i"; done
fi
log_sep; log_blank

# ==============================================================================
# FASE 2 — REPARAÇÕES SISTÊMICAS
# ==============================================================================
log_sep
log_info "FASE 2: REPARAÇÕES SISTÊMICAS"
log_sep

NEEDS_REBOOT=0   # Setado para 1 se fsck exigir reboot

for issue in "${SYSTEM_ISSUES[@]}"; do
    case "$issue" in

        READONLY_FS:*)
            rest="${issue#READONLY_FS:}"
            ro_dev="${rest%%:*}"   # /dev/sda2
            ro_mp="${rest#*:}"     # /  ou  /var  etc.

            log_fix "[FIX] Filesystem $ro_dev ($ro_mp) está SOMENTE LEITURA."

            # Tentativa 1: remount rw — funciona quando o erro foi transitório
            # (ex: timeout de I/O isolado sem corrupção estrutural)
            log_fix "  Tentando remount rw: mount -o remount,rw \"$ro_mp\" ..."
            if mount -o remount,rw "$ro_mp" 2>/dev/null; then
                log_ok "  Remount RW bem-sucedido: $ro_mp voltou a escrita normal."
                log_ok "  Prosseguindo com recuperação do PostgreSQL."
            else
                log_error "  Remount RW falhou — filesystem com erros estruturais."

                # Diagnóstico read-only: fsck -n é seguro em FS montado
                log_fix "  Rodando fsck -n $ro_dev (diagnóstico sem modificar)..."
                fsck -n "$ro_dev" 2>&1 | while IFS= read -r fline; do
                    log_fix "  FSCK-N >> $fline"
                done

                # Agenda fsck completo para execução durante o próximo boot
                log_fix "  Agendando fsck completo para o próximo boot..."
                if command -v tune2fs >/dev/null 2>&1; then
                    # Eleva o mount-count para forçar fsck no boot (ext2/3/4)
                    tune2fs -C 32 "$ro_dev" 2>/dev/null \
                        && log_ok "  tune2fs: fsck agendado em $ro_dev." \
                        || log_warn "  tune2fs falhou em $ro_dev (pode não ser ext2/3/4)."
                fi
                # Fallback legado (inócuo em Ubuntu 20.04 com systemd)
                touch /forcefsck 2>/dev/null

                NEEDS_REBOOT=1
            fi
            ;;

        STALE_SOCKETS|SOCKET_PERMS)
            log_fix "[FIX] Removendo sockets/locks residuais e recriando socket dir..."
            rm -f /var/run/postgresql/.s.PGSQL.* 2>/dev/null
            mkdir -p /var/run/postgresql
            chown postgres:postgres /var/run/postgresql
            chmod 2775 /var/run/postgresql
            log_ok "Socket dir limpo e recriado."
            ;;

        DISK_FULL:*)
            mountpoint="${issue#DISK_FULL:}"
            log_fix "[FIX] Disco cheio em $mountpoint — limpeza de choque iniciada..."

            # 1) Todos os logs do PostgreSQL — sem restrição de data
            log_fix "  Deletando TODOS os logs em /var/log/postgresql/..."
            rm -rf /var/log/postgresql/*.log 2>/dev/null
            rm -rf /var/log/postgresql/*.csv 2>/dev/null
            rm -rf /var/log/postgresql/*.gz  2>/dev/null

            # 2) Journal do sistema: mantém apenas a última hora
            if command -v journalctl >/dev/null 2>&1; then
                log_fix "  Truncando journal do sistema para a última hora..."
                journalctl --vacuum-time=1h 2>/dev/null
            fi

            # 3) /tmp completo — PDV dedicado, nada valioso aqui
            log_fix "  Esvaziando /tmp..."
            rm -rf /tmp/* 2>/dev/null

            # 4) Core dumps do postgres
            find /var/lib/postgresql \( -name "core" -o -name "core.*" \) \
                -exec rm -f {} + 2>/dev/null

            new_usage=$(df "$mountpoint" 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')
            log_info "  Uso após limpeza: ${new_usage:-?}%"
            if [ "${new_usage:-100}" -ge 95 ] 2>/dev/null; then
                log_warn "  Disco ainda acima de 95%. Maiores consumidores:"
                du -sh /var/lib/postgresql/*/main 2>/dev/null | sort -rh | head -5 \
                    | while IFS= read -r l; do log_warn "    $l"; done
            fi
            ;;

        PORT_CONFLICT:*:*)
            conflict_pid=$(echo "$issue" | cut -d: -f2)
            conflict_name=$(echo "$issue" | cut -d: -f3)
            log_fix "[FIX] Conflito de porta: eliminando '$conflict_name' (PID=$conflict_pid) com KILL -9..."
            pkill -9 -P "$conflict_pid" 2>/dev/null   # filhos primeiro
            kill -9 "$conflict_pid" 2>/dev/null
            sleep 1
            if command -v ss >/dev/null 2>&1 && ss -tlnp 2>/dev/null | grep -q ':5432 '; then
                log_warn "  Porta 5432 ainda ocupada. Executando _nuke_port_5432..."
                _nuke_port_5432
            else
                log_ok "  Porta 5432 liberada."
            fi
            ;;

        CROWDSTRIKE_ACTIVE)
            log_warn "[INFO] CrowdStrike com prevenção ativa. Não pode ser resolvido localmente."
            log_warn "  Contate TI: solicite exclusão de /usr/lib/postgresql/*/bin/postgres"
            log_warn "  Hostname: $(hostname 2>/dev/null)"
            ;;

        APPARMOR_ENFORCE)
            log_fix "[FIX] AppArmor ENFORCE para PostgreSQL — colocando em modo complain..."
            aa-complain /usr/lib/postgresql/*/bin/postgres 2>/dev/null && \
                log_ok "  AppArmor modo complain ativado." || \
                log_error "  Falha ao alterar AppArmor."
            ;;

        LOW_MEMORY)
            log_fix "[FIX] Memória crítica — liberando caches do kernel..."
            sync
            echo 3 > /proc/sys/vm/drop_caches 2>/dev/null && \
                log_ok "  Caches liberados (drop_caches=3)." || \
                log_warn "  Não foi possível liberar caches."
            ;;

        LOW_SHMMAX)
            log_fix "[FIX] Ajustando e persistindo kernel.shmmax = 128MB..."
            sysctl -w kernel.shmmax=134217728 2>/dev/null
            sysctl -w kernel.shmall=32768     2>/dev/null
            grep -q "^kernel.shmmax" /etc/sysctl.conf 2>/dev/null || \
                echo "kernel.shmmax = 134217728" >> /etc/sysctl.conf
            grep -q "^kernel.shmall" /etc/sysctl.conf 2>/dev/null || \
                echo "kernel.shmall = 32768" >> /etc/sysctl.conf
            log_ok "kernel.shmmax ajustado e persistido."
            ;;

        IO_ERRORS)
            # Não aborta: se o hardware estiver morto de vez, a recuperação vai falhar
            # naturalmente e um técnico será acionado. O custo do PDV parado é maior
            # do que o risco de tentar. EXT4 "re-mounted errors=remount-ro" pode ser
            # transitório — vale a tentativa.
            log_warn "[WARN] Erros de I/O detectados no kernel. Prosseguindo com tentativa de recuperação."
            log_warn "  Se o cluster não subir, acione manutenção de hardware (fsck -n <partição>)."
            ;;
    esac
done

# ==============================================================================
# PRÉ-FASE 3 — ARROMBAMENTO TOTAL DA PORTA 5432
# Executa ANTES de qualquer pg_ctlcluster start. Garante que absolutamente
# nada está ocupando a porta 5432 quando o loop de clusters começar.
# ==============================================================================
log_sep
log_fix "PRÉ-FASE 3: ARROMBAMENTO TOTAL DA PORTA 5432"
log_sep

log_fix "  fuser -k -9 5432/tcp (mata qualquer processo na porta via fuser)..."
if command -v fuser >/dev/null 2>&1; then
    fuser -k -9 5432/tcp 2>/dev/null && log_ok "  fuser: porta 5432 eliminada." \
        || log_info "  fuser: nada encontrado na porta 5432."
else
    log_warn "  fuser não disponível — usando pkill como fallback."
fi

log_fix "  pkill -9 -f postgres (mata TODOS os processos postgres remanescentes)..."
pkill -9 -f postgres 2>/dev/null && log_ok "  pkill: processos postgres eliminados." \
    || log_info "  pkill: nenhum processo postgres encontrado."

sleep 1
log_fix "  Limpeza kamikaze final de sockets e PID files residuais..."
rm -rf /var/run/postgresql/.s.PGSQL.* 2>/dev/null
mkdir -p /var/run/postgresql
chown postgres:postgres /var/run/postgresql
chmod 2775 /var/run/postgresql
log_ok "  Porta 5432 arrombada e zerada. Iniciando loop de clusters."

# ==============================================================================
# FASE 3 — LOOP DE CLUSTERS: DIAGNÓSTICO + SHOCK RECOVERY
# ==============================================================================
CLUSTER_LIST=$(pg_lsclusters -h 2>/dev/null)

if [ -z "$CLUSTER_LIST" ]; then
    log_error "Nenhum cluster PostgreSQL encontrado."
    exit 1
fi

log_blank; log_sep
log_info "FASE 3: SHOCK RECOVERY POR CLUSTER"
log_sep

while IFS= read -r line; do
    [ -z "$line" ] && continue
    read -r version cluster port status _ data_dir log_file <<< "$line"
    [ -z "$version" ] || [ -z "$data_dir" ] && continue

    log_blank; log_sep
    log_info "CLUSTER: PostgreSQL $version | $cluster | Porta: $port | Status: $status"
    log_info "Data dir: $data_dir"
    log_sep

    BIN_DIR="/usr/lib/postgresql/$version/bin"
    CLUSTER_ISSUES=()

    [ ! -d "$data_dir" ] && {
        log_error "Data dir '$data_dir' não existe. Cluster ignorado."
        OVERALL_STATUS=1; continue
    }

    # --------------------------------------------------------------------------
    # DIAGNÓSTICO DO CLUSTER
    # --------------------------------------------------------------------------
    log_info "--- DIAGNÓSTICO ---"

    # D.1: Binário
    pg_binary="$BIN_DIR/postgres"
    if [ ! -x "$pg_binary" ]; then
        log_error "Binário não encontrado: $pg_binary"
        log_error "  Cache local: ls /var/cache/apt/archives/postgresql-${version}_*.deb"
        CLUSTER_ISSUES+=("MISSING_BINARY")
    else
        bin_ver=$("$pg_binary" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
        log_ok "Binário: $pg_binary ($bin_ver)"
    fi

    # D.2: pg_control
    pg_control="$data_dir/global/pg_control"
    if [ ! -f "$pg_control" ]; then
        log_error "pg_control AUSENTE — corrupção severa."
        CLUSTER_ISSUES+=("MISSING_PG_CONTROL")
    else
        log_ok "pg_control presente."
        if [ -x "$BIN_DIR/pg_controldata" ]; then
            db_state=$(sudo -u postgres "$BIN_DIR/pg_controldata" "$data_dir" 2>/dev/null \
                       | grep "Database cluster state" | awk -F': ' '{print $2}' | xargs)
            log_info "Estado pg_controldata: '$db_state'"
            case "$db_state" in
                "in production"|"shut down") log_ok "Estado pg_control normal." ;;
                "in crash recovery"|"shutting down")
                    log_warn "Cluster em estado intermediário: '$db_state'."
                    CLUSTER_ISSUES+=("NEEDS_RESETWAL") ;;
                "")  log_warn "Não foi possível ler o estado do pg_controldata." ;;
                *)
                    log_warn "Estado incomum: '$db_state'."
                    CLUSTER_ISSUES+=("NEEDS_RESETWAL") ;;
            esac
        fi
    fi

    # D.3: WAL dir
    if [ -d "$data_dir/pg_wal" ]; then
        wal_dir="$data_dir/pg_wal"
        wal_count=$(find "$wal_dir" -maxdepth 1 -name "0*" 2>/dev/null | wc -l)
        log_info "pg_wal: $wal_count arquivo(s)."
        [ "$wal_count" -eq 0 ] && { log_error "WAL vazio!"; CLUSTER_ISSUES+=("NEEDS_RESETWAL"); }
    elif [ -d "$data_dir/pg_xlog" ]; then
        wal_dir="$data_dir/pg_xlog"
        wal_count=$(find "$wal_dir" -maxdepth 1 -name "0*" 2>/dev/null | wc -l)
        log_info "pg_xlog (legado): $wal_count arquivo(s)."
        [ "$wal_count" -eq 0 ] && { log_error "WAL vazio!"; CLUSTER_ISSUES+=("NEEDS_RESETWAL"); }
    else
        log_error "Diretório WAL não encontrado!"
        CLUSTER_ISSUES+=("NEEDS_RESETWAL")
    fi

    # D.4: postmaster.pid
    PID_FILE="$data_dir/postmaster.pid"
    [ -f "$PID_FILE" ] && {
        orphan_pid=$(head -1 "$PID_FILE" 2>/dev/null)
        kill -0 "$orphan_pid" 2>/dev/null \
            && log_warn "postmaster.pid com processo VIVO PID=$orphan_pid — será eliminado." \
            || log_warn "postmaster.pid ÓRFÃO (PID=$orphan_pid morto) — será removido."
        CLUSTER_ISSUES+=("STALE_PID_FILE")
    } || log_ok "Nenhum postmaster.pid presente."

    # D.5: Permissões do data_dir
    current_owner=$(stat -c '%U:%G' "$data_dir" 2>/dev/null)
    dir_perms=$(stat -c '%a'   "$data_dir" 2>/dev/null)
    log_info "Data dir: owner=$current_owner perms=$dir_perms"
    [ "$current_owner" != "postgres:postgres" ] && {
        log_warn "Owner incorreto: '$current_owner'."
        CLUSTER_ISSUES+=("WRONG_OWNER")
    }
    [ "$dir_perms" != "700" ] && {
        log_warn "Permissões incorretas: $dir_perms."
        CLUSTER_ISSUES+=("WRONG_PERMS")
    }

    # D.6: postgresql.conf
    pg_conf="$data_dir/postgresql.conf"
    conf_listen=""; conf_port=""; conf_sb=""
    if [ -f "$pg_conf" ]; then
        conf_listen=$(grep -E "^[[:space:]]*listen_addresses[[:space:]]*=" "$pg_conf" 2>/dev/null \
                      | tail -1 | awk -F'=' '{print $2}' | tr -d "'\" \t" | cut -d'#' -f1)
        conf_port=$(grep -E "^[[:space:]]*port[[:space:]]*=" "$pg_conf" 2>/dev/null \
                    | tail -1 | awk -F'=' '{print $2}' | tr -d " \t" | cut -d'#' -f1)
        conf_sb=$(grep -E "^[[:space:]]*shared_buffers[[:space:]]*=" "$pg_conf" 2>/dev/null \
                  | tail -1 | awk -F'=' '{print $2}' | tr -d " \t" | cut -d'#' -f1)
        log_info "postgresql.conf: listen='$conf_listen' port=$conf_port shared_buffers=$conf_sb"

        if [ -n "$conf_listen" ] && \
           [ "$conf_listen" != "*" ] && [ "$conf_listen" != "0.0.0.0" ] && \
           [ "$conf_listen" != "localhost" ] && [ "$conf_listen" != "127.0.0.1" ]; then
            log_warn "listen_addresses='$conf_listen' pode limitar conexões TCP."
            CLUSTER_ISSUES+=("LISTEN_ADDR:$conf_listen")
        fi

        if [ -n "$conf_sb" ]; then
            sb_value=$(echo "$conf_sb" | grep -oE '[0-9]+' | head -1)
            sb_unit=$( echo "$conf_sb" | grep -oE '[A-Za-z]+' | head -1)
            sb_bytes=0
            if [ -n "$sb_value" ]; then
                case "${sb_unit,,}" in
                    gb) sb_bytes=$(( sb_value * 1024 * 1024 * 1024 )) ;;
                    mb) sb_bytes=$(( sb_value * 1024 * 1024 )) ;;
                    kb) sb_bytes=$(( sb_value * 1024 )) ;;
                    *)  sb_bytes=$(( sb_value * 8192 )) ;;
                esac
                # Comparação via awk — seguro para shmmax > 2^63 (ULONG_MAX Linux)
                if awk -v sb="$sb_bytes" -v sm="$shmmax" \
                       'BEGIN { exit (sb>0 && sm>0 && sb>sm) ? 0 : 1 }'; then
                    log_error "shared_buffers ($conf_sb) excede kernel.shmmax!"
                    CLUSTER_ISSUES+=("SHARED_BUFFERS_TOO_HIGH")
                fi
            fi
        fi

        [ -n "$conf_port" ] && [ "$conf_port" != "$port" ] && {
            log_warn "Porta no conf ($conf_port) difere da esperada ($port)."
            CLUSTER_ISSUES+=("PORT_MISMATCH:$conf_port")
        }
    else
        log_warn "postgresql.conf não encontrado."
        CLUSTER_ISSUES+=("MISSING_PG_CONF")
    fi

    # D.7: pg_hba.conf
    pg_hba="$data_dir/pg_hba.conf"
    if [ -f "$pg_hba" ]; then
        reject_rule=$(grep -E "^host[[:space:]]+all[[:space:]]+all.*reject" "$pg_hba" 2>/dev/null)
        [ -n "$reject_rule" ] && {
            log_warn "pg_hba.conf tem regra REJECT global."
            CLUSTER_ISSUES+=("HBA_REJECT_ALL")
        } || log_ok "pg_hba.conf sem REJECT global."
    else
        log_warn "pg_hba.conf não encontrado."
        CLUSTER_ISSUES+=("MISSING_PG_HBA")
    fi

    log_blank
    if [ ${#CLUSTER_ISSUES[@]} -eq 0 ]; then
        log_ok "Nenhum problema no cluster."
    else
        log_warn "Problemas no cluster ${version}/${cluster}:"
        for ci in "${CLUSTER_ISSUES[@]}"; do log_warn "  -> $ci"; done
    fi

    # Único bloqueante real: sem binário, não há nada a fazer
    for ci in "${CLUSTER_ISSUES[@]}"; do
        [ "$ci" = "MISSING_BINARY" ] && {
            log_error "Binário ausente — cluster ignorado."
            OVERALL_STATUS=1; continue 2
        }
    done

    # --------------------------------------------------------------------------
    # SHOCK RECOVERY DO CLUSTER
    # --------------------------------------------------------------------------
    log_info "--- SHOCK RECOVERY ---"

    # R.1: Derrubar TUDO relacionado ao cluster — sem cerimônia
    log_fix "[R 1/8] Derrubando serviço e TODA árvore de processos do cluster..."

    # Tenta parada graciosa por GRACEFUL_STOP_TIMEOUT=2s
    local_service="postgresql@${version}-${cluster}"
    if systemctl list-units --type=service --all 2>/dev/null | grep -qF "${local_service}.service"; then
        systemctl stop "$local_service" 2>/dev/null &
    else
        systemctl stop postgresql 2>/dev/null &
    fi
    pg_ctlcluster "$version" "$cluster" stop 2>/dev/null &

    elapsed=0
    while pg_ctlcluster "$version" "$cluster" status >/dev/null 2>&1 \
          && [ $elapsed -lt $GRACEFUL_STOP_TIMEOUT ]; do
        sleep 1; elapsed=$(( elapsed + 1 ))
    done

    # Se ainda rodando após 2s: kill -9 imediato em toda a árvore
    if pg_ctlcluster "$version" "$cluster" status >/dev/null 2>&1 \
       || [ -f "$PID_FILE" ] && kill -0 "$(head -1 "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
        log_fix "  Timeout (${GRACEFUL_STOP_TIMEOUT}s). KILL -9 na árvore de processos..."
        if [ -f "$PID_FILE" ]; then
            main_pid=$(head -1 "$PID_FILE" 2>/dev/null)
            if [ -n "$main_pid" ]; then
                pkill -9 -P "$main_pid" 2>/dev/null   # filhos
                kill  -9 "$main_pid"    2>/dev/null   # pai
            fi
        fi
        # Nuclear: qualquer processo postgres vinculado a este data_dir
        pkill -9 -f "postgres.*${data_dir}" 2>/dev/null
        sleep 1
    else
        log_ok "  Serviço encerrado em ${elapsed}s."
    fi

    # Garante que a porta 5432 está livre — mata QUALQUER coisa que estiver lá
    _nuke_port_5432

    # R.2: Limpeza kamikaze — rm incondicional de tudo que bloqueia o start
    log_fix "[R 2/8] Limpeza kamikaze de PID files, locks e sockets..."
    _kamikaze_cleanup "$data_dir" "$port"

    # R.3: Correção RECURSIVA de owner e permissões
    perm_fix_needed=0
    for ci in "${CLUSTER_ISSUES[@]}"; do
        case "$ci" in WRONG_OWNER|WRONG_PERMS) perm_fix_needed=1; break ;; esac
    done
    if [ $perm_fix_needed -eq 1 ]; then
        log_fix "[R 3/8] Corrigindo owner/permissões (recursivo)..."
        chown -R postgres:postgres "$data_dir"
        chmod 700 "$data_dir"
        find "$data_dir" -mindepth 1 -type d -exec chmod 700 {} \; 2>/dev/null
        find "$data_dir" -mindepth 1 -type f -exec chmod 600 {} \; 2>/dev/null
        log_ok "  Permissões corrigidas recursivamente."
    fi

    # R.4: Ajuste de shared_buffers
    for ci in "${CLUSTER_ISSUES[@]}"; do
        [ "$ci" = "SHARED_BUFFERS_TOO_HIGH" ] && [ -f "$pg_conf" ] && {
            log_fix "[R 4/8] Ajustando shared_buffers..."
            cp "$pg_conf" "${pg_conf}.bak.$(date +%Y%m%d%H%M%S%N)" 2>/dev/null
            ram_raw=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
            ram_mb=$(( ${ram_raw:-0} / 1024 ))
            safe_sb=$(( ram_mb / 4 ))
            [ $safe_sb -lt 128 ] && safe_sb=128
            [ $safe_sb -gt 512 ] && safe_sb=512
            sed -i "s|^[[:space:]]*shared_buffers[[:space:]]*=.*|shared_buffers = ${safe_sb}MB|" "$pg_conf"
            log_ok "  shared_buffers ajustado para ${safe_sb}MB."
        }
    done

    # R.5: Corrigir listen_addresses
    for ci in "${CLUSTER_ISSUES[@]}"; do
        [[ "$ci" == LISTEN_ADDR:* ]] && [ -f "$pg_conf" ] && {
            bad_listen="${ci#LISTEN_ADDR:}"
            log_fix "[R 5/8] Corrigindo listen_addresses='$bad_listen' → 'localhost'..."
            cp "$pg_conf" "${pg_conf}.bak.$(date +%Y%m%d%H%M%S%N)" 2>/dev/null
            if grep -qE "^[[:space:]]*listen_addresses[[:space:]]*=" "$pg_conf" 2>/dev/null; then
                sed -i "s|^[[:space:]]*listen_addresses[[:space:]]*=.*|listen_addresses = 'localhost'|" "$pg_conf"
            else
                echo "listen_addresses = 'localhost'" >> "$pg_conf"
            fi
            log_ok "  listen_addresses corrigido."
        }
    done

    # R.6: Corrigir pg_hba.conf
    for ci in "${CLUSTER_ISSUES[@]}"; do
        case "$ci" in
            HBA_REJECT_ALL)
                log_fix "[R 6/8] Comentando regra REJECT global no pg_hba.conf..."
                cp "$pg_hba" "${pg_hba}.bak.$(date +%Y%m%d%H%M%S%N)" 2>/dev/null
                sed -i 's|^\(host[[:space:]]\+all[[:space:]]\+all.*reject\)|# COMENTADO SHOCK_RECOVERY: \1|Ig' "$pg_hba"
                log_ok "  Regra REJECT comentada."
                ;;
            MISSING_PG_HBA)
                log_fix "[R 6/8] Criando pg_hba.conf mínimo..."
                cat > "$pg_hba" << 'EOF'
# Gerado pelo Shock Recovery Script
local   all   postgres                 peer
local   all   all                      md5
host    all   all   127.0.0.1/32       md5
host    all   all   ::1/128            md5
EOF
                chown postgres:postgres "$pg_hba"
                chmod 640 "$pg_hba"
                log_ok "  pg_hba.conf mínimo criado."
                ;;
        esac
    done

    # R.7: pg_resetwal PROATIVO se o estado do cluster indica corrupção de WAL
    for ci in "${CLUSTER_ISSUES[@]}"; do
        [ "$ci" = "NEEDS_RESETWAL" ] && [ -x "$BIN_DIR/pg_resetwal" ] && {
            log_fix "[R 7/8] Estado de WAL corrompido detectado PRÉ-START — executando pg_resetwal -f..."
            sudo -u postgres "$BIN_DIR/pg_resetwal" -f "$data_dir" 2>&1 \
                | while IFS= read -r l; do log_fix "  RESETWAL >> $l"; done
            log_ok "  pg_resetwal -f concluído."
            break
        }
    done

    # R.8: START — com fallback extremo automático em caso de falha
    log_fix "[R 8/8] Iniciando cluster PostgreSQL ${version}/${cluster}..."
    start_output=$(pg_ctlcluster "$version" "$cluster" start 2>&1)
    start_exit=$?
    log_info "pg_ctlcluster start: $start_output"

    if [ $start_exit -ne 0 ]; then
        log_error "Falha no start (código $start_exit). Coletando diagnóstico..."

        # Exibe as últimas linhas do log do cluster
        pg_log_path="$log_file"
        [ -z "$pg_log_path" ] || [ ! -f "$pg_log_path" ] && \
            pg_log_path=$(find /var/log/postgresql -name "postgresql-${version}-${cluster}*" 2>/dev/null \
                          | sort | tail -1)
        if [ -n "$pg_log_path" ] && [ -f "$pg_log_path" ]; then
            log_warn "Últimas 30 linhas de $pg_log_path:"
            tail -30 "$pg_log_path" | while IFS= read -r l; do log_warn "  PG_LOG >> $l"; done
        fi

        pg_log_tail=""
        [ -n "$pg_log_path" ] && [ -f "$pg_log_path" ] && pg_log_tail=$(tail -10 "$pg_log_path" 2>/dev/null)
        combined="${start_output}${pg_log_tail}"

        # ======================================================================
        # FALLBACK EXTREMO — pg_resetwal -f incondicional
        # Justificativa: a central RD tem o espelho dos dados. O PDV parado
        # tem custo maior do que qualquer transação local não-commitada.
        # ======================================================================
        if [ -x "$BIN_DIR/pg_resetwal" ]; then
            log_fix ">>> FALLBACK EXTREMO: pg_resetwal -f — forçando reset de timeline..."
            sudo -u postgres "$BIN_DIR/pg_resetwal" -f "$data_dir" 2>&1 \
                | while IFS= read -r l; do log_fix "  RESETWAL >> $l"; done

            sleep 1
            _kamikaze_cleanup "$data_dir" "$port"

            log_fix ">>> Retentando start após pg_resetwal..."
            start_output=$(pg_ctlcluster "$version" "$cluster" start 2>&1)
            start_exit=$?
            log_info "  Retry start: $start_output"
        fi

        # Se ainda falhou após pg_resetwal, tenta zero_damaged_pages
        if [ $start_exit -ne 0 ] && \
           echo "$combined" | grep -qi "invalid page\|checksum\|could not read block"; then
            log_fix ">>> Habilitando zero_damaged_pages=on para corrupção de página..."
            [ -f "$pg_conf" ] && {
                cp "$pg_conf" "${pg_conf}.bak.$(date +%Y%m%d%H%M%S%N)" 2>/dev/null
                grep -q "^zero_damaged_pages" "$pg_conf" 2>/dev/null || \
                    echo "zero_damaged_pages = on" >> "$pg_conf"
            }
            start_output=$(pg_ctlcluster "$version" "$cluster" start 2>&1)
            start_exit=$?
            log_info "  Retry com zero_damaged_pages: $start_output"
        fi

        if [ $start_exit -ne 0 ]; then
            log_error "Cluster ${version}/${cluster} não subiu após todos os fallbacks."
            log_error "  Última saída: $start_output"
            log_error "  Última saída do log PG: $(tail -5 "$pg_log_path" 2>/dev/null)"
            OVERALL_STATUS=1
            continue
        fi
    fi

    log_ok "Cluster iniciado. Aguardando estabilização (5s)..."
    sleep 5

    # --------------------------------------------------------------------------
    # Validação de conectividade e saúde
    # --------------------------------------------------------------------------
    log_info "--- VALIDAÇÃO ---"

    if sudo -u postgres psql -p "$port" -c "SELECT version();" >/dev/null 2>&1; then
        log_ok "Conexão local (socket Unix) OK."
    else
        log_error "Conexão via socket Unix FALHOU. Verifique pg_hba.conf: $pg_hba"
        OVERALL_STATUS=1; continue
    fi

    if sudo -u postgres psql -h 127.0.0.1 -p "$port" -c "SELECT 1;" >/dev/null 2>&1; then
        log_ok "Conexão TCP (127.0.0.1:$port) OK."
    else
        log_warn "Conexão TCP FALHOU (socket Unix OK — não bloqueante para PDV local)."
    fi

    in_recovery=$(sudo -u postgres psql -p "$port" -t \
                  -c "SELECT pg_is_in_recovery();" 2>/dev/null | xargs)
    [ "$in_recovery" = "t" ] \
        && log_warn "Banco em RECOVERY. Aguarde conclusão." \
        || log_ok "Banco NOT in recovery — pronto para uso."

    log_ok "Bancos de dados disponíveis:"
    sudo -u postgres psql -p "$port" -t \
        -c "SELECT datname FROM pg_database WHERE datistemplate=false ORDER BY datname;" \
        2>/dev/null \
        | awk 'NF{$1=$1; print "  -> " $0}' \
        | while IFS= read -r l; do log_ok "$l"; done

    conn_count=$(sudo -u postgres psql -p "$port" -t \
                 -c "SELECT count(*) FROM pg_stat_activity WHERE state IS NOT NULL;" \
                 2>/dev/null | xargs)
    log_ok "Conexões ativas: ${conn_count:-0}"

    log_info "Tamanho dos bancos:"
    sudo -u postgres psql -p "$port" -t \
        -c "SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database WHERE datistemplate=false ORDER BY pg_database_size(datname) DESC;" \
        2>/dev/null \
        | awk 'NF{$1=$1; print "  " $0}' \
        | while IFS= read -r l; do log_info "$l"; done

    log_fix "Iniciando VACUUM ANALYZE em background..."
    sudo -u postgres vacuumdb -p "$port" --all --analyze-in-stages 2>/dev/null &
    log_ok "VACUUM ANALYZE em background (PID=$!)."

    log_sep
    log_ok "SUCESSO: PostgreSQL $version/$cluster OPERACIONAL na porta $port."
    log_ok "PDV LIBERADO."
    log_sep

done <<< "$CLUSTER_LIST"

# ==============================================================================
# RESULTADO FINAL
# ==============================================================================
log_blank; log_sep
log_info "SHOCK RECOVERY FINALIZADO: $(date '+%Y-%m-%d %H:%M:%S')"
log_info "Log completo: $LOG_FILE"
if [ $OVERALL_STATUS -eq 0 ]; then
    log_ok "RESULTADO: TODOS OS CLUSTERS OPERACIONAIS."
else
    log_error "RESULTADO: UM OU MAIS CLUSTERS FALHARAM. Verifique o log: $LOG_FILE"
fi
log_sep

# ==============================================================================
# REBOOT + AUTODELETE — só executa se AMBAS as condições forem verdadeiras:
#   1. NEEDS_REBOOT=1: filesystem estava RO e remount rw falhou (fsck necessário)
#   2. OVERALL_STATUS!=0: o PostgreSQL NÃO subiu — o RO foi realmente o impeditivo
#
# Se o Postgres subiu mesmo com NEEDS_REBOOT=1 (ex: data_dir em outra partição),
# o reboot é descartado — não há motivo para interromper um PDV funcionando.
# ==============================================================================
if [ "$NEEDS_REBOOT" -eq 1 ] && [ "$OVERALL_STATUS" -ne 0 ]; then
    log_sep
    log_fix "FILESYSTEM RO FOI O IMPEDITIVO — EXECUTANDO FSCK + REBOOT"
    log_fix "  O systemd-fsck reparará o disco durante o boot."
    log_fix "  Após reiniciar, reexecute o script para finalizar a recuperação."
    log_sep

    # Apaga o script ANTES do reboot — o arquivo some do disco mas o processo
    # continua em memória (comportamento normal do bash/Linux).
    SCRIPT_PATH="$(realpath "$0" 2>/dev/null || echo "$0")"
    rm -f "$SCRIPT_PATH" 2>/dev/null && \
        log_fix "  Script removido: $SCRIPT_PATH" || \
        log_warn "  Não foi possível remover $SCRIPT_PATH"

    sync
    shutdown -r now "SHOCK RECOVERY: fsck necessário — reboot automático" 2>/dev/null \
        || reboot 2>/dev/null
    exit 0
fi

exit $OVERALL_STATUS
