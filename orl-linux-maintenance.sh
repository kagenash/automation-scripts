#!/usr/bin/env bash
# =============================================================================
# orl3.0.sh — Script de Manutenção Automatizada para Linux
# Autor   : João Victor Pires Pinheiro de Lima
# Versão  : 3.0 (Refatoração corporativa)
# =============================================================================
# Descrição:
#   Realiza limpeza de cache, otimização de parâmetros de kernel, ajuste de
#   I/O scheduler, desfragmentação/TRIM e reinicialização automática com
#   auto-deleção segura do script.
#
# Requisitos:
#   - Bash 4.3+ (para namerefs via local -n)
#   - Execução como root
#   - Kernel Linux 3.x+ (sysctl.d/, /proc/sys, sysfs scheduler)
#
# Reversão das otimizações:
#   - Kernel : rm -f /etc/sysctl.d/90-orl-optimization.conf && sysctl --system
#   - I/O    : rm -f /etc/udev/rules.d/60-io-schedulers.rules
# =============================================================================

set -euo pipefail

# PATH explícito: previne PATH-hijacking em ambientes com $PATH comprometido.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

# =============================================================================
# CONSTANTES GLOBAIS (readonly: imutáveis após definição)
# =============================================================================

readonly SCRIPT_VERSION="3.0"

# BASH_SOURCE[0] retorna o path real do script mesmo com 'bash script.sh',
# diferente de $0 que pode apontar para o interpretador em alguns contextos.
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"; readonly SCRIPT_NAME

# Resolve para path absoluto imediatamente — BASH_SOURCE[0] retorna path relativo
# quando invocado como 'bash orl3.0.sh', o que quebraria a auto-deleção se o $PWD mudar.
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"; readonly SCRIPT_PATH

# Log desta ferramenta — separado dos logs do sistema para não poluir /var/log
readonly ORL_LOG="/var/log/orl-manutencao.log"

# Arquivo sysctl dedicado em sysctl.d/ — NÃO modifica /etc/sysctl.conf
# Vantagens: sem duplicatas, reversão trivial, precedência definida pelo kernel
readonly SYSCTL_CONF_FILE="/etc/sysctl.d/90-orl-optimization.conf"

# Arquivo de regras udev dedicado — reversível removendo apenas este arquivo
readonly UDEV_RULES_FILE="/etc/udev/rules.d/60-io-schedulers.rules"

# Diretório específico do sistema PDV (ponto de venda)
readonly PDV_DIR="/pdv"

# Parâmetros de kernel desejados (formato "chave=valor")
# Os valores são extraídos por expansão de parâmetro (sem subshells)
readonly -a SYSCTL_PARAMS=(
    # ── Memória ──────────────────────────────────────────────────────────────
    "vm.swappiness=10"                  # Prefere RAM; recorre ao swap só em pressão alta
    "vm.dirty_ratio=10"                 # Bloqueia escritas ao atingir 10% de páginas sujas
    "vm.dirty_background_ratio=5"       # Inicia flush em background a 5%
    "vm.dirty_expire_centisecs=500"     # Descarta páginas sujas após 5 s (padrão: 30 s)
    "vm.dirty_writeback_centisecs=100"  # Writeback a cada 1 s (padrão: 5 s)
    "vm.vfs_cache_pressure=50"          # Balanceia retenção de cache de inodes vs. pagecache
    "vm.min_free_kbytes=65536"          # Reserva 64 MiB para alocações de emergência do kernel
    # ── CPU scheduler (CFS) ──────────────────────────────────────────────────
    "kernel.sched_min_granularity_ns=1000000"    # Granularidade mínima 1 ms (padrão: ~4 ms)
    "kernel.sched_wakeup_granularity_ns=1500000" # Granularidade de wakeup 1,5 ms
    # ── Segurança de rede ────────────────────────────────────────────────────
    "net.ipv4.tcp_syncookies=1"         # Proteção contra SYN flood
    "net.core.somaxconn=1024"           # Backlog de conexões TCP aceitas
    # ── Buffers TCP ──────────────────────────────────────────────────────────
    "net.core.rmem_max=16777216"        # Buffer máximo de recepção por socket (16 MiB)
    "net.core.wmem_max=16777216"        # Buffer máximo de envio por socket (16 MiB)
    "net.ipv4.tcp_rmem=4096 262144 16777216"  # TCP rx: mínimo / padrão / máximo
    "net.ipv4.tcp_wmem=4096 262144 16777216"  # TCP tx: mínimo / padrão / máximo
    # ── Latência de conexão ───────────────────────────────────────────────────
    "net.ipv4.tcp_fastopen=3"           # TCP Fast Open client+server — elimina RTT extra
    "net.ipv4.tcp_fin_timeout=15"       # FIN_WAIT_2 de 60 s → 15 s
    "net.ipv4.tcp_keepalive_time=600"   # Keepalive após 10 min idle (padrão: 2 h)
    "net.ipv4.tcp_keepalive_intvl=30"   # Intervalo entre probes (padrão: 75 s)
    "net.ipv4.tcp_keepalive_probes=5"   # Nº de probes antes de descartar (padrão: 9)
    "net.ipv4.tcp_tw_reuse=1"           # Reutiliza sockets TIME_WAIT para novas conexões
)

# --- Códigos de cor ANSI para saída formatada ---
readonly C_RESET='\033[0m'
readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[1;33m'
readonly C_BLUE='\033[0;34m'
readonly C_CYAN='\033[0;36m'
readonly C_BOLD='\033[1m'

# =============================================================================
# ESTADO GLOBAL MUTÁVEL
# =============================================================================

# Array para rastrear TODOS os arquivos temporários criados durante a execução.
# O handler_exit garante a remoção completa mesmo em caso de SIGINT/SIGTERM/erro.
declare -a TMPFILES=()

# Gerenciador de pacotes detectado (preenchido por detect_pkg_manager)
PKG_MANAGER=""  

# =============================================================================
# FUNÇÕES DE LOG E SAÍDA
# =============================================================================

# log: Exibe mensagem formatada no terminal e registra no arquivo de log.
# Uso  : log <NÍVEL> <mensagem>
# Níveis: INFO | SUCCESS | WARN | ERROR | SECTION
log() {
    local level="${1:?log: argumento NÍVEL obrigatório}"
    local msg="${2:?log: argumento MENSAGEM obrigatório}"
    local ts color

    ts="$(date '+%Y-%m-%d %H:%M:%S')"

    case "$level" in
        INFO)    color="${C_BLUE}"           ;;
        SUCCESS) color="${C_GREEN}"          ;;
        WARN)    color="${C_YELLOW}"         ;;
        ERROR)   color="${C_RED}"            ;;
        SECTION) color="${C_CYAN}${C_BOLD}"  ;;
        *)       color="${C_RESET}"          ;;
    esac

    # Saída colorida no terminal (stdout)
    printf "${color}[%s] [%-7s] %s${C_RESET}\n" "$ts" "$level" "$msg"

    # Registro sem escapes ANSI no arquivo de log (append)
    printf '[%s] [%-7s] %s\n' "$ts" "$level" "$msg" >> "$ORL_LOG" 2>/dev/null || true
}

# =============================================================================
# TRATAMENTO DE SINAIS E LIMPEZA GLOBAL
# =============================================================================

# cleanup_tmpfiles: Remove todos os arquivos do array TMPFILES.
# Chamada pelo handler_exit em qualquer condição de encerramento.
cleanup_tmpfiles() {
    local f
    # "${TMPFILES[@]+"${TMPFILES[@]}"}" expande com segurança mesmo com array vazio (set -u)
    for f in "${TMPFILES[@]+"${TMPFILES[@]}"}"; do
        [[ -f "$f" ]] && rm -f -- "$f" 2>/dev/null || true
    done
}

# handler_exit: Executado automaticamente em qualquer saída (normal, erro ou sinal).
# Garante limpeza dos temporários e exibe mensagem de erro se código != 0.
handler_exit() {
    local code=$?
    cleanup_tmpfiles
    if [[ $code -ne 0 ]]; then
        printf '[ERRO] Script encerrado com código %d. Verifique: %s\n' \
            "$code" "$ORL_LOG" >&2
    fi
}

# Registra os handlers uma única vez. EXIT cobre: saída normal, set -e, e sinais
# que usam exit (como os traps de INT e TERM abaixo).
trap 'handler_exit'                                               EXIT
trap 'log WARN "SIGINT recebido (Ctrl+C). Abortando..."; exit 130' INT
trap 'log WARN "SIGTERM recebido. Encerrando..."         ; exit 143' TERM

# =============================================================================
# FUNÇÕES UTILITÁRIAS
# =============================================================================

# check_root: Garante que o script seja executado como root.
# Encerra com código 1 caso contrário.
check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        log ERROR "Este script deve ser executado como root (sudo)."
        exit 1
    fi
}

# detect_pkg_manager: Detecta o gerenciador de pacotes disponível e preenche
# a variável global PKG_MANAGER. Suporta: apt, dnf, yum, zypper, pacman.
# Se nenhum for encontrado, PKG_MANAGER fica vazio e a limpeza de cache é pulada.
detect_pkg_manager() {
    if   command -v apt-get >/dev/null 2>&1; then PKG_MANAGER="apt"
    elif command -v dnf     >/dev/null 2>&1; then PKG_MANAGER="dnf"
    elif command -v yum     >/dev/null 2>&1; then PKG_MANAGER="yum"
    elif command -v zypper  >/dev/null 2>&1; then PKG_MANAGER="zypper"
    elif command -v pacman  >/dev/null 2>&1; then PKG_MANAGER="pacman"
    else                                          PKG_MANAGER=""
    fi
    readonly PKG_MANAGER
    log INFO "Gerenciador de pacotes: ${PKG_MANAGER:-nenhum detectado}"
}

# make_tmpfile: Cria arquivo temporário via mktemp e registra no array TMPFILES.
# Usa nameref (local -n, bash 4.3+) para evitar subshell ao retornar o path —
# uma chamada via $() criaria um subshell que não propagaria TMPFILES ao pai.
# Uso: local f; make_tmpfile f
make_tmpfile() {
    local -n _tmpfile_ref="${1:?make_tmpfile: nome de variável obrigatório}"
    _tmpfile_ref="$(mktemp)"
    TMPFILES+=("$_tmpfile_ref")
}

# =============================================================================
# FUNÇÕES DE MANUTENÇÃO
# =============================================================================

# clean_system: Remove arquivos de /tmp e /var/tmp e limpa cache de pacotes.
# -mindepth 1 preserva os próprios diretórios, removendo apenas o conteúdo.
clean_system() {
    log SECTION "--- Limpando arquivos temporários e cache de pacotes ---"

    find /tmp     -mindepth 1 -delete 2>/dev/null || true
    find /var/tmp -mindepth 1 -delete 2>/dev/null || true
    log INFO "Diretórios /tmp e /var/tmp limpos."

    # Limpa cache conforme o gerenciador detectado.
    # DEBIAN_FRONTEND=noninteractive evita prompts interativos do apt.
    case "$PKG_MANAGER" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get clean -q 2>/dev/null || true
            DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -q 2>/dev/null || true
            log SUCCESS "Cache APT limpo e pacotes órfãos removidos."
            ;;
        dnf|yum)
            "$PKG_MANAGER" clean all -q 2>/dev/null || true
            log SUCCESS "Cache ${PKG_MANAGER} limpo."
            ;;
        zypper)
            zypper clean --all 2>/dev/null || true
            log SUCCESS "Cache Zypper limpo."
            ;;
        pacman)
            pacman -Sc --noconfirm 2>/dev/null || true
            log SUCCESS "Cache Pacman limpo."
            ;;
        "")
            log WARN "Nenhum gerenciador de pacotes detectado. Cache de pacotes não limpo."
            ;;
    esac
}

# clear_caches: Libera caches de memória RAM via /proc/sys/vm/drop_caches.
# Valor 3 = pagecache + dentries + inodes (mais agressivo; ideal para manutenção).
# Em produção de alto throughput, considere '1' para limpar apenas o pagecache.
clear_caches() {
    log SECTION "--- Liberando cache de memória RAM ---"

    # sync garante que dados pendentes em buffer sejam gravados antes de liberar
    sync

    # Usa 'tee' para capturar o exit code real da escrita no procfs — 'echo 3 > file'
    # retorna o exit code do echo (sempre 0), não da escrita. 'tee' reflete o status do fd.
    if echo 3 | tee /proc/sys/vm/drop_caches >/dev/null 2>&1; then
        log SUCCESS "Caches de pagecache, dentries e inodes liberados com sucesso."
    else
        log WARN "Falha ao escrever em /proc/sys/vm/drop_caches (container sem CAP_SYS_ADMIN ou kernel sem suporte)."
    fi
}

# clean_pdv: Remove arquivos de diagnóstico/log gerados pelo sistema PDV.
clean_pdv() {
    if [[ ! -d "$PDV_DIR" ]]; then
        log INFO "Diretório $PDV_DIR não encontrado. Pulando limpeza do PDV."
        return 0
    fi

    log SECTION "--- Limpando diretório $PDV_DIR ---"

    # Padrões de nomes de arquivos gerados pelo software CliSiTef e integrados ao PDV
    find "$PDV_DIR" -type f \( \
        -name "CliSiTef.20*" \
        -o -name "hs*"       \
        -o -name "CO*"       \
        -o -name "Erro*"     \
        -o -name "eplog_*"   \
    \) -delete 2>/dev/null || true

    log SUCCESS "Diretório $PDV_DIR limpo."
}

# clean_logs: Rotaciona e/ou limpa logs do sistema de forma SEGURA.
#
# POR QUE "truncate -s 0" EM ARQUIVOS ABERTOS É PROBLEMÁTICO EM PRODUÇÃO:
#   Embora o truncate preserve o inode (não quebra file descriptors existentes),
#   truncar arquivos que daemons de auditoria estão escrevendo (auditd, rsyslog,
#   agentes SIEM) sem sinalizar o daemon para reabrir o arquivo cria problemas:
#
#   1. O daemon continua escrevendo com O_APPEND a partir do EOF (offset 0 após
#      o truncate), mas o agente SIEM já indexou os bytes anteriores. Ao tentar
#      ler do offset antigo, encontrará dados incompatíveis ou ausentes.
#   2. Arquivos de /var/log/audit/ têm integridade gerenciada pelo auditd.
#      Truncá-los externamente pode violar políticas de conformidade (PCI-DSS,
#      HIPAA, SOX) e gerar alertas nos sistemas de segurança.
#
# ABORDAGEM DESTA FUNÇÃO (três camadas, da mais à menos segura):
#   1. logrotate --force  : solução oficial; notifica daemons via sinais (HUP/USR1)
#   2. journalctl --vacuum: gerencia o journal systemd com limites seguros
#   3. Truncagem seletiva : só para arquivos .log NÃO abertos por processos ativos,
#      excluindo explicitamente caminhos de auditoria críticos. Preserva
#      permissões (chmod) e ownership (chown) originais via stat.
clean_logs() {
    log SECTION "--- Rotacionando logs do sistema com segurança ---"

    # --- Camada 1: logrotate (abordagem recomendada para produção) ---
    if command -v logrotate >/dev/null 2>&1; then
        # --force ignora timestamps e força rotação imediata de todos os logs
        if logrotate --force /etc/logrotate.conf >/dev/null 2>&1; then
            log SUCCESS "Logrotate: rotação forçada concluída."
        else
            # Código não-zero do logrotate costuma ser aviso (ex: arquivo já rotacionado)
            log WARN "Logrotate retornou aviso. Inspecione /var/lib/logrotate/status se necessário."
        fi
    else
        log WARN "logrotate não encontrado. Usando método alternativo de limpeza."
    fi

    # --- Camada 2: compactação do journal systemd ---
    if command -v journalctl >/dev/null 2>&1; then
        # Mantém os logs dos últimos 30 dias ou 200 MB (o que for menor)
        journalctl --vacuum-time=30d --vacuum-size=200M >/dev/null 2>&1 || true
        log INFO "Journal systemd compactado (retenção: 30 dias / 200 MB)."
    fi

    # --- Camada 3: truncagem conservadora de arquivos .log inativos ---
    # Verifica disponibilidade do fuser E acesso ao /proc — em containers sem /proc
    # montado corretamente o binário existe mas falha em runtime, produzindo falso-negativo
    # (interpretaria "arquivo em uso" como "arquivo livre") e truncaria logs abertos.
    local has_fuser=0
    if command -v fuser >/dev/null 2>&1 && [[ -d /proc/1 ]]; then
        has_fuser=1
    fi

    local cleaned=0 skipped=0 protected=0
    local f perm owner group

    while IFS= read -r -d '' f; do
        # Protege arquivos de auditoria do kernel — gerenciados exclusivamente pelo auditd
        if [[ "$f" == /var/log/audit/* ]]; then
            (( ++protected )) || true; continue
        fi
        # Protege journal do systemd — gerenciado exclusivamente pelo journald
        if [[ "$f" == /var/log/journal/* ]]; then
            (( ++protected )) || true; continue
        fi

        # Pula arquivos que estão com file descriptors abertos por processos ativos.
        # fuser retorna 0 se o arquivo está em uso, 1 se não está.
        if [[ $has_fuser -eq 1 ]]; then
            if fuser "$f" >/dev/null 2>&1; then
                log WARN "Em uso por processo ativo (preservando): $f"
                (( ++skipped )) || true; continue
            fi
        fi

        # Captura metadados antes de qualquer modificação para restauração fiel
        perm="$(stat  -c '%a' "$f" 2>/dev/null)" || continue
        owner="$(stat -c '%U' "$f" 2>/dev/null)" || continue
        group="$(stat -c '%G' "$f" 2>/dev/null)" || continue

        # Trunca in-place com redirecionamento builtin do shell.
        # ': > file' preserva o inode (FDs abertos continuam válidos), sem invocar
        # o binário externo truncate. É seguro e compatível com POSIX.
        if : > "$f" 2>/dev/null; then
            chmod  "$perm"            "$f" 2>/dev/null || true
            chown  "${owner}:${group}" "$f" 2>/dev/null || true
            (( ++cleaned )) || true
        else
            log WARN "Sem permissão para truncar: $f"
            (( ++skipped )) || true
        fi

    done < <(find /var/log -maxdepth 3 -type f -name "*.log" -print0 2>/dev/null)

    log SUCCESS "Logs: ${cleaned} truncados, ${skipped} preservados (em uso), ${protected} protegidos (auditoria)."
}

# check_file_permissions: Audita permissões de arquivos críticos de segurança.
# Compara valores reais com os esperados segundo CIS Benchmark para Linux.
check_file_permissions() {
    log SECTION "--- Verificando permissões de arquivos críticos (CIS Benchmark) ---"

    # Mapeamento arquivo → permissão octal esperada
    local -A expected_perms=(
        ["/etc/passwd"]="644"   # Legível por todos; sem escrita para não-root
        ["/etc/shadow"]="640"   # Apenas root + grupo shadow (senhas hasheadas)
        ["/etc/group"]="644"    # Legível por todos
        ["/etc/sudoers"]="440"  # Somente leitura pelo root e grupo sudo
    )

    local issues=0 f expected actual

    for f in "${!expected_perms[@]}"; do
        [[ ! -f "$f" ]] && continue
        expected="${expected_perms[$f]}"
        # stat -c '%a' retorna permissões em octal sem o bit de tipo (ex: "640")
        actual="$(stat -c '%a' "$f" 2>/dev/null)" || continue

        if [[ "$actual" == "$expected" ]]; then
            log INFO "  OK [${actual}] $f"
        else
            log WARN "  DIVERGÊNCIA: $f — atual=${actual} | esperado=${expected}"
            (( ++issues )) || true
        fi
    done

    if [[ $issues -gt 0 ]]; then
        log WARN "$issues arquivo(s) com permissões divergentes. Revisão manual recomendada."
    else
        log SUCCESS "Permissões de todos os arquivos críticos estão corretas."
    fi
}

# check_disk_space: Exibe uso de disco para dispositivos /dev/*.
# Usa passagem única de awk para eliminar a cadeia grep | awk | tr.
check_disk_space() {
    log SECTION "--- Uso de disco atual ---"

    # -h: legível por humanos  -P: saída POSIX (sem quebras de linha em nomes longos)
    # awk processa cabeçalho e filtra /dev/ em uma única execução, sem pipes extras
    df -hP | awk '
        /^Filesystem/ { print; next }
        /^\/dev\//    { print }
    '
}

# optimize_system_params: Aplica parâmetros de kernel para otimização de memória e I/O.
#
# IDEMPOTÊNCIA:
#   Os parâmetros são escritos em /etc/sysctl.d/90-orl-optimization.conf.
#   Antes de escrever, a função compara os parâmetros desejados com os existentes
#   (ignorando linhas de comentário e data que sempre mudariam). O arquivo só
#   é reescrito se houver diferença real nos valores — evitando escritas em disco
#   e triggers desnecessários em sistemas de monitoramento de integridade (AIDE, Tripwire).
optimize_system_params() {
    log SECTION "--- Ajustando parâmetros de Kernel ---"

    local key value param

    # --- Verificação de idempotência ---
    # Extrai apenas as linhas de parâmetro (sem comentários) do arquivo atual
    local existing_params=""
    if [[ -f "$SYSCTL_CONF_FILE" ]]; then
        existing_params="$(grep -v '^[[:space:]]*#' "$SYSCTL_CONF_FILE" \
                           | grep -v '^[[:space:]]*$' \
                           | tr -d ' ' \
                           | sort)"
    fi

    # Gera a lista de parâmetros desejados no mesmo formato para comparação
    local desired_params=""
    for param in "${SYSCTL_PARAMS[@]}"; do
        # Remove espaços ao redor do '=' para comparação normalizada
        desired_params+="${param//[[:space:]]/}"$'\n'
    done
    desired_params="$(printf '%s' "$desired_params" | sort)"

    local needs_write=1
    [[ "$existing_params" == "$desired_params" ]] && needs_write=0

    if [[ $needs_write -eq 1 ]]; then
        # Grava o arquivo de configuração com cabeçalho informativo
        {
            printf '# Otimizações de kernel — %s v%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
            printf '# Gerado em: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
            printf '# Para reverter: rm -f %s && sysctl --system\n\n' "$SYSCTL_CONF_FILE"
            for param in "${SYSCTL_PARAMS[@]}"; do
                printf '%s\n' "$param"
            done
        } > "$SYSCTL_CONF_FILE"
        log INFO "Arquivo $SYSCTL_CONF_FILE atualizado."
    else
        log INFO "Parâmetros sysctl inalterados — sem necessidade de reescrita."
    fi

    # --- Aplicação imediata dos parâmetros via sysctl -w ---
    # Usa expansão de parâmetro bash para extrair chave e valor (sem subshell/cut)
    local errors=0
    for param in "${SYSCTL_PARAMS[@]}"; do
        key="${param%%=*}"    # Tudo antes do primeiro '='
        value="${param#*=}"   # Tudo após o primeiro '='
        if ! sysctl -w "${key}=${value}" >/dev/null 2>&1; then
            log WARN "Falha ao aplicar imediatamente: ${key}=${value}"
            (( ++errors )) || true
        fi
    done

    # Recarrega sysctl.d/ completo para garantir consistência.
    # --system lê todos os arquivos em /etc/sysctl.d/ (kernels modernos).
    # Fallback para -p no arquivo específico em kernels mais antigos.
    if ! sysctl --system >/dev/null 2>&1; then
        sysctl -p "$SYSCTL_CONF_FILE" >/dev/null 2>&1 || true
    fi

    if [[ $errors -eq 0 ]]; then
        log SUCCESS "Todos os parâmetros de kernel aplicados com sucesso."
    else
        log WARN "$errors parâmetro(s) falharam na aplicação imediata (podem já estar corretos)."
    fi
}

# optimize_io_scheduler: Detecta cada disco e aplica o I/O scheduler ideal.
#
# LÓGICA DE SELEÇÃO:
#   HDD (rotacional=1): BFQ > CFQ  — melhor QoS para I/O misto sequencial/aleatório
#   SSD/NVMe (rotacional=0): mq-deadline > noop/none  — baixa latência, sem reordenação
#
# IDEMPOTÊNCIA:
#   Compara as regras udev geradas com as existentes no arquivo (ignorando
#   comentários/data). Só reescreve e recarrega udevadm se houver mudança real.
optimize_io_scheduler() {
    log SECTION "--- Otimizando I/O Scheduler ---"

    # nullglob: sem discos correspondentes, o glob retorna array vazio (não a string literal)
    local old_nullglob
    old_nullglob="$(shopt -p nullglob)"
    shopt -s nullglob

    local rules_lines=""
    local rules_count=0
    local dev_path dev_name is_rotational schedulers current best

    for dev_path in /sys/block/sd* /sys/block/nvme*n* /sys/block/vd* /sys/block/xvd* /sys/block/mmcblk*; do
        [[ ! -d "$dev_path/queue" ]] && continue

        dev_name="$(basename "$dev_path")"

        # Lê atributos do sysfs; usa cat para permitir 2>/dev/null e guard de falha.
        # Sem o guard, um arquivo ausente acionaria set -e e abortaria o script inteiro.
        is_rotational="$(cat "$dev_path/queue/rotational" 2>/dev/null)" \
            || { log WARN "  > Falha ao ler rotational de $dev_name. Pulando."; continue; }
        schedulers="$(cat "$dev_path/queue/scheduler" 2>/dev/null)" \
            || { log WARN "  > Falha ao ler scheduler de $dev_name. Pulando."; continue; }

        # Extrai o scheduler ativo (marcado com colchetes no sysfs, ex: "[bfq] cfq mq-deadline")
        # grep -o '\[[^]]*\]' extrai o padrão de colchetes sem ser guloso
        current="$(printf '%s' "$schedulers" | grep -o '\[[^]]*\]' | tr -d '[]')"
        best=""

        log INFO "Disco: $dev_name | rotacional: $is_rotational | scheduler atual: ${current:-desconhecido}"

        # Comparação de string evita erro "integer expression expected" se o arquivo
        # contiver conteúdo inesperado — [[ -eq 1 ]] abortaria o script via set -e.
        if [[ "$is_rotational" == "1" ]]; then
            if   [[ "$schedulers" == *"bfq"* ]]; then best="bfq"
            elif [[ "$schedulers" == *"cfq"* ]]; then best="cfq"
            fi
        else
            if   [[ "$schedulers" == *"mq-deadline"* ]]; then best="mq-deadline"
            elif [[ "$schedulers" == *"noop"* ]];         then best="noop"
            elif [[ "$schedulers" == *"none"* ]];         then best="none"
            fi
        fi

        if [[ -z "$best" ]]; then
            log WARN "  > Nenhum scheduler otimizado disponível para $dev_name."
            continue
        fi

        # Acumula a linha de regra udev para escrita posterior
        rules_lines+="ACTION==\"add|change\", KERNEL==\"${dev_name}\", ATTR{queue/scheduler}=\"${best}\"\n"
        (( ++rules_count )) || true

        # Aplica o scheduler imediatamente (sem aguardar reboot)
        if [[ "$current" != "$best" ]]; then
            if echo "$best" > "$dev_path/queue/scheduler" 2>/dev/null; then
                log SUCCESS "  > Scheduler '$best' aplicado em $dev_name (era '$current')."
            else
                log WARN "  > Falha ao aplicar '$best' em $dev_name (suporte no kernel?)."
            fi
        else
            log INFO "  > $dev_name: scheduler '$current' já é o ideal. Sem alteração."
        fi
    done

    # Restaura o estado anterior do nullglob (boa prática de isolamento)
    eval "$old_nullglob"

    if [[ $rules_count -eq 0 ]]; then
        log WARN "Nenhum disco com scheduler configurável encontrado. Regras udev não alteradas."
        return 0
    fi

    # --- Verificação de idempotência das regras udev ---
    # Compara apenas as linhas de regra, ignorando comentários e a linha de data
    local needs_udev_write=1
    if [[ -f "$UDEV_RULES_FILE" ]]; then
        local existing_rules new_rules
        existing_rules="$(grep -v '^[[:space:]]*#' "$UDEV_RULES_FILE" \
                          | grep -v '^[[:space:]]*$')"
        new_rules="$(printf '%b' "$rules_lines" | grep -v '^[[:space:]]*$')"
        [[ "$existing_rules" == "$new_rules" ]] && needs_udev_write=0
    fi

    if [[ $needs_udev_write -eq 1 ]]; then
        {
            printf '# I/O Scheduler rules — %s v%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
            printf '# Gerado em: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
            printf '# Para reverter: rm -f %s\n\n' "$UDEV_RULES_FILE"
            printf '%b' "$rules_lines"
        } > "$UDEV_RULES_FILE"

        udevadm control --reload-rules                            >/dev/null 2>&1 || true
        # --subsystem-match=block --action=change limita o trigger ao subsistema de
        # disco, evitando re-processamento de todos os dispositivos do sistema
        # (rede, USB, PCI...) que udevadm trigger sem argumentos dispararia.
        udevadm trigger --subsystem-match=block --action=change  >/dev/null 2>&1 || true
        log SUCCESS "Regras udev escritas e recarregadas ($rules_count disco(s) configurado(s))."
    else
        log INFO "Regras udev já estão atualizadas. Nenhuma reescrita necessária."
    fi

    log SUCCESS "Otimização de I/O Scheduler concluída."
}

# _progress_bar: Exibe barra de progresso animada enquanto monitora um PID filho.
# Uso   : _progress_bar <pid> <label>
# Retorna: código de saída real do processo monitorado
#
# ROBUSTEZ E CONCORRÊNCIA:
#   kill -0 PID: verifica existência do processo de forma atômica (sem corrida de PID).
#   A construção da barra usa apenas builtins bash (sem subshells no loop principal).
#   'wait PID && s=0 || s=$?' captura o exit code real sem acionar set -e.
_progress_bar() {
    local child_pid="${1:?_progress_bar: PID obrigatório}"
    local label="${2:-Processando...}"
    local bar_width=50
    local i=0
    local filled_str child_status j

    while kill -0 "$child_pid" 2>/dev/null; do
        i=$(( (i + 1) % bar_width ))

        # Constrói a string de progresso usando apenas concatenação bash (sem subshell)
        filled_str=""
        for (( j = 0; j < i; j++ )); do filled_str+="#"; done

        printf "\r  ${C_CYAN}[%-${bar_width}s]${C_RESET} %s" "$filled_str" "$label"
        sleep 0.2
    done

    # Captura o exit code real do filho. O padrão 'cmd && var=0 || var=$?' é necessário:
    # 'wait' com exit code != 0 acionaria set -e se usado diretamente.
    wait "$child_pid" 2>/dev/null && child_status=0 || child_status=$?

    # Limpa a linha da barra de progresso antes de retornar
    printf '\r%-80s\r' ' '

    return "$child_status"
}

# defrag_system: Executa TRIM (SSD) ou desfragmentação e4defrag (HDD) em partições ext4.
#
# FLUXO POR PARTIÇÃO:
#   1. Tenta fstrim (TRIM): ideal para SSDs. Timeout de 1 hora.
#   2. Se TRIM falha com código != 124 (timeout), tenta e4defrag para HDDs. Timeout de 2 horas.
#   3. Se somente e4defrag disponível, usa direto.
#
# SEGURANÇA DE TEMPORÁRIOS:
#   Todos os arquivos temporários são criados via make_tmpfile (nameref), que os
#   registra em TMPFILES. O handler_exit os remove em qualquer condição de saída,
#   eliminando a necessidade de traps individuais por operação.
defrag_system() {
    log SECTION "--- Otimização de Armazenamento (TRIM / Defrag ext4) ---"

    # Obtém partições ext4 em passagem única de awk — evita pipes encadeados
    # Saída: "DISPOSITIVO PONTO_DE_MONTAGEM" por linha
    local targets
    targets="$(df -TP | awk 'NR>1 && $2=="ext4" {print $1, $NF}')"

    if [[ -z "$targets" ]]; then
        log INFO "Nenhuma partição ext4 encontrada para otimização."
        return 0
    fi

    # Verifica disponibilidade das ferramentas uma única vez, antes do loop
    local has_fstrim=0 has_e4defrag=0
    command -v fstrim   >/dev/null 2>&1 && has_fstrim=1
    command -v e4defrag >/dev/null 2>&1 && has_e4defrag=1

    if [[ $has_fstrim -eq 0 && $has_e4defrag -eq 0 ]]; then
        log WARN "Nem fstrim nem e4defrag disponíveis. Pulando otimização de armazenamento."
        return 0
    fi

    local dev mnt out_file child_pid rc

    while IFS=' ' read -r dev mnt; do
        log INFO "Processando partição: $mnt ($dev)"

        # --- Tentativa 1: TRIM via fstrim ---
        if [[ $has_fstrim -eq 1 ]]; then
            log INFO "  > Tentando TRIM (fstrim)..."

            # make_tmpfile via nameref: registra o temp em TMPFILES (sem subshell)
            make_tmpfile out_file

            # Executa fstrim em background com timeout de 1 hora (3600s)
            timeout 3600 fstrim -v "$mnt" > "$out_file" 2>&1 &
            child_pid=$!

            if _progress_bar "$child_pid" "TRIM em $mnt"; then
                log SUCCESS "  > TRIM concluído: $(< "$out_file")"
                rm -f "$out_file" 2>/dev/null || true
                continue   # Partição tratada; próxima iteração do while
            else
                rc=$?
                rm -f "$out_file" 2>/dev/null || true

                if [[ $rc -eq 124 ]]; then
                    log WARN "  > TRIM em $mnt excedeu o timeout de 1 hora. Pulando."
                    continue
                fi
                # rc=1: TRIM não suportado (partição em HDD ou TRIM desabilitado)
                # Cai para tentativa com e4defrag abaixo
                log INFO "  > TRIM não suportado em $mnt (cód. $rc). Tentando desfragmentação..."
            fi
        fi

        # --- Tentativa 2: Desfragmentação via e4defrag ---
        if [[ $has_e4defrag -eq 1 ]]; then
            log INFO "  > Executando desfragmentação (e4defrag)..."

            make_tmpfile out_file

            # Executa e4defrag em background com timeout de 2 horas (7200s)
            timeout 7200 e4defrag -v "$mnt" > "$out_file" 2>&1 &
            child_pid=$!

            if _progress_bar "$child_pid" "Defrag em $mnt"; then
                log SUCCESS "  > Desfragmentação concluída em $mnt."
            else
                rc=$?
                if [[ $rc -eq 124 ]]; then
                    log WARN "  > Desfragmentação em $mnt excedeu o timeout de 2 horas."
                else
                    log WARN "  > Desfragmentação falhou em $mnt (cód. $rc)."
                fi
            fi
            rm -f "$out_file" 2>/dev/null || true
        else
            log WARN "  > e4defrag não disponível. Partição $mnt não pôde ser desfragmentada."
        fi

    done <<< "$targets"

    log SUCCESS "Otimização de armazenamento finalizada."
}

# reboot_system: Auto-deleta o script do disco e reinicia o sistema.
#
# SEGURANÇA DA AUTO-DELEÇÃO:
#   'rm -f -- "$SCRIPT_PATH"' usa o path capturado no início da execução
#   via BASH_SOURCE[0]. O double-dash (--) protege contra paths que começam
#   com '-'. Se a remoção falhar, o script registra aviso mas continua o reboot.
reboot_system() {
    log SECTION "============================================================"
    log SUCCESS "MANUTENÇÃO CONCLUÍDA. Log completo em: $ORL_LOG"
    log SECTION "============================================================"

    # Auto-deleção do script
    if [[ -f "$SCRIPT_PATH" ]]; then
        rm -f -- "$SCRIPT_PATH" 2>/dev/null \
            || log WARN "Não foi possível remover o script. Remova manualmente: $SCRIPT_PATH"
        log INFO "Script removido do disco."
    fi

    log WARN "O sistema será REINICIADO automaticamente em 10 segundos."
    log WARN "Pressione CTRL+C agora para cancelar."

    local i
    for (( i = 10; i >= 1; i-- )); do
        printf "  %d... " "$i"
        sleep 1
    done
    printf '\n'

    log INFO "Sincronizando buffers de I/O e reiniciando..."
    sync
    reboot
}

# tune_thp: configura Transparent Huge Pages para 'madvise'.
#
# POR QUE NÃO 'always':
#   THP 'always' força o khugepaged a compactar memória continuamente,
#   causando picos de latência de 10–200 ms sem aviso. 'madvise' restringe
#   THP a aplicações que o solicitam explicitamente (JVMs, bancos de dados),
#   sem impor o overhead ao restante do sistema.
#
# DEFRAG 'defer+madvise' (kernel ≥ 4.13):
#   Adia compactação para o kswapd, nunca bloqueando alocações do caminho
#   crítico. Fallback automático para 'madvise' em kernels mais antigos.
tune_thp() {
    log SECTION "--- Ajustando Transparent Huge Pages (THP) ---"

    local thp_enabled="/sys/kernel/mm/transparent_hugepage/enabled"
    local thp_defrag="/sys/kernel/mm/transparent_hugepage/defrag"

    if [[ ! -f "$thp_enabled" ]]; then
        log INFO "THP não disponível neste kernel. Pulando."
        return 0
    fi

    local current_thp changed=0
    current_thp="$(< "$thp_enabled")"

    if [[ "$current_thp" != *"[madvise]"* ]]; then
        if echo "madvise" > "$thp_enabled" 2>/dev/null; then
            log SUCCESS "THP: 'madvise' aplicado (anterior: ${current_thp})."
            (( ++changed )) || true
        else
            log WARN "Falha ao configurar THP (CAP_SYS_ADMIN ausente?)."
        fi
    else
        log INFO "THP: já em 'madvise'. Sem alteração."
    fi

    if [[ -f "$thp_defrag" ]]; then
        local current_defrag target_defrag="defer+madvise"
        current_defrag="$(< "$thp_defrag")"

        if [[ "$current_defrag" != *"[${target_defrag}]"* ]]; then
            if ! echo "$target_defrag" > "$thp_defrag" 2>/dev/null; then
                target_defrag="madvise"
                echo "$target_defrag" > "$thp_defrag" 2>/dev/null || true
            fi
            log SUCCESS "THP defrag: '${target_defrag}' aplicado."
            (( ++changed )) || true
        else
            log INFO "THP defrag: já em '${target_defrag}'. Sem alteração."
        fi
    fi

    [[ $changed -eq 0 ]] && log INFO "THP já configurado corretamente."
}

# tune_cpu_governor: ajusta o governor de frequência de CPU.
#
# LÓGICA DE SELEÇÃO (ordem de preferência):
#   1. schedutil  — adaptativo via CFS; reage em microssegundos (vs. ms do ondemand).
#   2. performance — clock máximo constante; máximo throughput, maior consumo.
#   ondemand/powersave introduzem ramp latency de clock — descartados.
#
# Silencioso em VMs sem exposição de cpufreq e kernels sem CONFIG_CPU_FREQ.
tune_cpu_governor() {
    log SECTION "--- Ajustando CPU Governor ---"

    local old_nullglob
    old_nullglob="$(shopt -p nullglob)"
    shopt -s nullglob

    local changed=0 already_ok=0 target_gov=""
    local gov_path

    for gov_path in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [[ -f "$gov_path" ]] || continue

        local current_gov available_govs
        current_gov="$(< "$gov_path")"
        available_govs="$(< "${gov_path/scaling_governor/scaling_available_governors}" 2>/dev/null)" \
            || available_govs=""

        if   [[ "$available_govs" == *"schedutil"*  ]]; then target_gov="schedutil"
        elif [[ "$available_govs" == *"performance"* ]]; then target_gov="performance"
        else continue
        fi

        if [[ "$current_gov" == "$target_gov" ]]; then
            (( ++already_ok )) || true
            continue
        fi

        if echo "$target_gov" > "$gov_path" 2>/dev/null; then
            (( ++changed )) || true
        fi
    done

    eval "$old_nullglob"

    if   [[ $changed    -gt 0 ]]; then log SUCCESS "CPU governor ajustado para '${target_gov}' em $changed CPU(s)."
    elif [[ $already_ok -gt 0 ]]; then log INFO    "CPU governor: $already_ok CPU(s) já no governor otimizado."
    else                                log INFO    "cpufreq não disponível (VM/container sem exposição de governor)."
    fi
}

# =============================================================================
# PONTO DE ENTRADA
# =============================================================================
main() {
    # Inicializa o arquivo de log com cabeçalho da sessão (append)
    {
        printf '\n'
        printf '=%.0s' {1..60}
        printf '\n'
        printf '[%s] Iniciando %s v%s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" "$SCRIPT_NAME" "$SCRIPT_VERSION"
    } >> "$ORL_LOG" 2>/dev/null || true

    clear
    printf '%s%s' "${C_BOLD}" "${C_CYAN}"
    printf '============================================================\n'
    printf '   MANUTENÇÃO AUTOMATIZADA LINUX — %s v%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
    printf '============================================================\n'
    printf '%s\n' "${C_RESET}"

    check_root
    detect_pkg_manager

    # Execução sequencial das etapas de manutenção.
    # set -e está ativo: um erro não capturado dentro de qualquer função encerrará
    # o script e acionará handler_exit automaticamente.
    # O padrão '|| log WARN' permite que etapas não-críticas falhem sem abortar
    # todo o processo — a falha é registrada e a execução continua.
    clean_system           || log WARN "clean_system: falha parcial. Continuando..."
    clear_caches           || log WARN "clear_caches: falha. Continuando..."
    clean_pdv              || log WARN "clean_pdv: falha. Continuando..."
    clean_logs             || log WARN "clean_logs: falha. Continuando..."
    check_file_permissions || log WARN "check_file_permissions: falha. Continuando..."
    check_disk_space       || log WARN "check_disk_space: falha. Continuando..."
    optimize_system_params || log WARN "optimize_system_params: falha. Continuando..."
    tune_thp               || log WARN "tune_thp: falha. Continuando..."
    tune_cpu_governor      || log WARN "tune_cpu_governor: falha. Continuando..."
    optimize_io_scheduler  || log WARN "optimize_io_scheduler: falha. Continuando..."
    defrag_system          || log WARN "defrag_system: falha parcial. Continuando..."

    # Etapa crítica: não usa '|| log WARN' — falha aqui deve ser investigada
    reboot_system
}

main "$@"
