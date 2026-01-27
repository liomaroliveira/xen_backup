#!/bin/bash
# ============================================================
# PROXMOX MASTER SUITE V2.4
# Funcionalidades: Suite Completa + Importação de Config XenServer
# ============================================================

# --- CONFIGURAÇÕES ---
LOG_FILE="/var/log/pve_master_tool_$(date +%Y%m%d_%H%M).log"
DATE_NOW=$(date +%Y-%m-%d_%H-%M)
HOSTNAME=$(hostname)

# --- CORES ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- FUNÇÕES DE SISTEMA ---

log() {
    local msg="$1"
    local level="${2:-INFO}"
    local color=""
    case $level in
        "INFO") color=$BLUE ;;
        "SUCCESS") color=$GREEN ;;
        "WARN") color=$YELLOW ;;
        "ERROR") color=$RED ;;
    esac
    echo -e "${color}[$(date +'%H:%M:%S')] [$level] $msg${NC}"
    echo "[$(date +'%H:%M:%S')] [$level] $msg" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"
    sync "$LOG_FILE"
}

cleanup_on_cancel() {
    echo ""
    log "!!! INTERRUPÇÃO DETECTADA !!!" "ERROR"
    pkill -P $$ 2>/dev/null
    exit 1
}
trap cleanup_on_cancel INT TERM

# --- 1. DETECÇÃO DE ARMAZENAMENTO ---

detect_storage() {
    local prompt_msg="$1"
    echo ""
    log "$prompt_msg"
    
    mapfile -t DISKS < <(lsblk -rn -o NAME,SIZE,TRAN,MOUNTPOINT | grep "usb" | grep -v "sda")
    [ ${#DISKS[@]} -eq 0 ] && mapfile -t DISKS < <(lsblk -rn -o NAME,SIZE,TRAN,MOUNTPOINT | grep "sd" | grep -v "sda")

    echo "  [0] Diretório Local (Digitar caminho manual)"
    i=1
    for disk in "${DISKS[@]}"; do
        echo "  [$i] USB: /dev/$disk"
        ((i++))
    done
    
    read -p "Opção: " disk_opt
    
    if [ "$disk_opt" == "0" ]; then
        read -p "Digite o caminho completo (ex: /mnt/pve/backups): " custom_path
        if [ -d "$custom_path" ]; then
            WORK_DIR="$custom_path"
        else
            log "Diretório inválido." "ERROR"; exit 1
        fi
    elif [ "$disk_opt" -gt 0 ] && [ "$disk_opt" -le "${#DISKS[@]}" ]; then
        SELECTED_DISK_LINE="${DISKS[$((disk_opt-1))]}"
        SELECTED_DEV="/dev/$(echo $SELECTED_DISK_LINE | awk '{print $1}')"
        WORK_DIR="/mnt/pve_master_usb"
        mkdir -p $WORK_DIR
        
        CURRENT_MOUNT=$(echo $SELECTED_DISK_LINE | awk '{print $4}')
        if [ -n "$CURRENT_MOUNT" ]; then
            WORK_DIR="$CURRENT_MOUNT"
        else
            mount $SELECTED_DEV $WORK_DIR
        fi
    else
        log "Opção inválida." "ERROR"; exit 1
    fi
    log "Diretório de Trabalho: $WORK_DIR" "SUCCESS"
}

# --- 2. EXPORTAÇÃO (BACKUP) ---

run_export() {
    detect_storage "SELECIONE O DESTINO DO BACKUP:"
    log "--- EXPORTAÇÃO DE VMS ---"
    
    qm list
    echo "-------------------------------------"
    echo "Digite IDs (separados por espaço) ou 'ALL':"
    read -p "Seleção: " selection
    
    if [ "$selection" == "ALL" ] || [ "$selection" == "all" ]; then
        mapfile -t TARGET_VMS < <(qm list | awk 'NR>1 {print $1}')
    else
        TARGET_VMS=($selection)
    fi
    
    echo "Modo: [1] Snapshot (Padrão) | [2] Suspend | [3] Stop"
    read -p "Opção [1]: " mode_opt
    case $mode_opt in
        2) BKP_MODE="suspend" ;;
        3) BKP_MODE="stop" ;;
        *) BKP_MODE="snapshot" ;;
    esac
    
    idx=1; total=${#TARGET_VMS[@]}
    for vmid in "${TARGET_VMS[@]}"; do
        vmname=$(qm config $vmid | grep "name:" | awk '{print $2}')
        [ -z "$vmname" ] && vmname="VM$vmid"
        clean_vmname=$(echo "$vmname" | tr -dc '[:alnum:]\-\_')
        
        echo ""
        log ">>> Exportando $idx/$total: $vmid ($vmname)"
        
        vzdump $vmid --dumpdir "$WORK_DIR" --mode $BKP_MODE --compress zstd
        
        if [ $? -eq 0 ]; then
            LATEST_FILE=$(find "$WORK_DIR" -maxdepth 1 -name "vzdump-qemu-$vmid-*.vma.zst" -mmin -2 | sort -r | head -n 1)
            
            if [ -f "$LATEST_FILE" ]; then
                NEW_NAME="$WORK_DIR/vzdump-qemu-${vmid}-${clean_vmname}-${DATE_NOW}.vma.zst"
                mv "$LATEST_FILE" "$NEW_NAME"
                log "    [SUCESSO] Salvo como: $(basename "$NEW_NAME")" "SUCCESS"
            else
                log "    [SUCESSO] Backup concluído (Renomeação falhou, arquivo original mantido)." "WARN"
            fi
        else
            log "    [ERRO] Falha ao exportar VM $vmid." "ERROR"
        fi
        ((idx++))
    done
}

# --- 3. IMPORTAÇÃO (RESTORE) ---

run_import() {
    detect_storage "SELECIONE A ORIGEM DO BACKUP:"
    log "Buscando backups em $WORK_DIR..."
    mapfile -t FILES < <(find "$WORK_DIR" -maxdepth 2 -name "*.vma*" | sort)
    
    if [ ${#FILES[@]} -eq 0 ]; then log "Nenhum backup encontrado."; return; fi
    
    echo "---------------------------------------------------------"
    i=1
    for f in "${FILES[@]}"; do
        fname=$(basename "$f")
        size=$(ls -lh "$f" | awk '{print $5}')
        echo "  [$i] $fname ($size)"
        ((i++))
    done
    echo "---------------------------------------------------------"
    
    read -p "Selecione o arquivo: " file_opt
    BACKUP_FILE="${FILES[$((file_opt-1))]}"
    
    NEXT_ID=$(pvesh get /cluster/nextid)
    read -p "Novo ID [$NEXT_ID]: " NEW_VMID; NEW_VMID=${NEW_VMID:-$NEXT_ID}
    
    if qm status $NEW_VMID &>/dev/null; then log "ID $NEW_VMID já existe!" "ERROR"; return; fi
    
    log "Selecione o Storage de Destino:"
    mapfile -t STORAGES < <(pvesm status -enabled | awk 'NR>1 {print $1}')
    i=1
    for store in "${STORAGES[@]}"; do
        info=$(pvesm status -storage "$store" | awk 'NR==2 {print $6}')
        human=$(numfmt --from-unit=1024 --to=iec $info 2>/dev/null || echo $info)
        echo "  [$i] $store (Livre: $human)"
        ((i++))
    done
    read -p "Opção: " store_opt
    TARGET_STORAGE="${STORAGES[$((store_opt-1))]}"
    
    log "Restaurando $(basename "$BACKUP_FILE") para VM $NEW_VMID em $TARGET_STORAGE..."
    qmrestore "$BACKUP_FILE" "$NEW_VMID" --storage "$TARGET_STORAGE"
    
    if [ $? -eq 0 ]; then log "SUCESSO! VM Restaurada." "SUCCESS"; else log "ERRO na restauração." "ERROR"; fi
}

# --- 4. CONFIGURAÇÕES DO HOST (HÍBRIDO: PROXMOX E XEN) ---

export_host_config() {
    detect_storage "DESTINO PARA EXPORTAR CONFIGS DO HOST:"
    EXPORT_PATH="$WORK_DIR/HOST_CONFIG_${HOSTNAME}_${DATE_NOW}.tar.gz"
    
    log "Coletando configurações..."
    TMP_DIR="/tmp/pve_export_conf_$$"
    mkdir -p "$TMP_DIR/etc_network" "$TMP_DIR/etc_pve"
    
    cp /etc/network/interfaces "$TMP_DIR/etc_network/" 2>/dev/null
    cp /etc/hosts "$TMP_DIR/" 2>/dev/null
    cp /etc/resolv.conf "$TMP_DIR/" 2>/dev/null
    cp /etc/pve/storage.cfg "$TMP_DIR/etc_pve/" 2>/dev/null
    cp /etc/pve/user.cfg "$TMP_DIR/etc_pve/" 2>/dev/null
    
    lsblk > "$TMP_DIR/disk_layout.txt"
    ip addr > "$TMP_DIR/ip_addr.txt"
    
    tar -czf "$EXPORT_PATH" -C "$TMP_DIR" .
    rm -rf "$TMP_DIR"
    
    log "Configurações exportadas para: $EXPORT_PATH" "SUCCESS"
}

import_host_config() {
    detect_storage "ORIGEM DAS CONFIGURAÇÕES:"
    
    echo ""
    log "Qual tipo de importação deseja realizar?"
    echo "  [1] Backup Proxmox (Arquivo .tar.gz)"
    echo "  [2] Migração XenServer (Arquivo de Auditoria .txt)"
    read -p "Opção: " type_opt
    
    if [ "$type_opt" == "1" ]; then
        # === MODO PROXMOX NATIVO ===
        mapfile -t FILES < <(find "$WORK_DIR" -name "HOST_CONFIG_*.tar.gz" | sort)
        if [ ${#FILES[@]} -eq 0 ]; then log "Nenhum arquivo .tar.gz encontrado."; return; fi
        
        echo "Arquivos disponíveis:"
        i=1
        for f in "${FILES[@]}"; do echo "  [$i] $(basename "$f")"; ((i++)); done
        read -p "Selecione: " f_opt
        CONF_FILE="${FILES[$((f_opt-1))]}"
        
        TMP_IMPORT="/tmp/pve_import_conf_$$"
        mkdir -p "$TMP_IMPORT"
        tar -xf "$CONF_FILE" -C "$TMP_IMPORT"
        
        log "MODO INTERATIVO DE IMPORTAÇÃO"
        read -p "Pressione ENTER para revisar a REDE (/etc/network/interfaces)..."
        nano "$TMP_IMPORT/etc_network/interfaces"
        
        echo ""
        log "Deseja aplicar esta configuração de rede?" "WARN"
        log "[1] Sim, aplicar e reiniciar rede (ifreload)"
        log "[2] Sim, aplicar mas NÃO reiniciar"
        log "[3] Não aplicar rede"
        read -p "Opção: " net_opt
        
        if [ "$net_opt" == "1" ] || [ "$net_opt" == "2" ]; then
            cp /etc/network/interfaces /etc/network/interfaces.BAK_$(date +%s)
            cp "$TMP_IMPORT/etc_network/interfaces" /etc/network/interfaces
            if [ "$net_opt" == "1" ]; then ifreload -a; fi
        fi
        
        read -p "Deseja importar Storage e Usuários (/etc/pve/*)? [y/N]: " pve_opt
        if [[ "$pve_opt" =~ ^[yY]$ ]]; then
            cp /etc/pve/storage.cfg /etc/pve/storage.cfg.BAK
            cp "$TMP_IMPORT/etc_pve/storage.cfg" /etc/pve/storage.cfg
            cp "$TMP_IMPORT/etc_pve/user.cfg" /etc/pve/user.cfg
            log "Storages e Usuários atualizados." "SUCCESS"
        fi
        rm -rf "$TMP_IMPORT"
        
    elif [ "$type_opt" == "2" ]; then
        # === MODO MIGRAÇÃO XENSERVER ===
        mapfile -t FILES < <(find "$WORK_DIR" -name "SERVER_*_INFO.txt" | sort)
        if [ ${#FILES[@]} -eq 0 ]; then log "Nenhum relatório XenServer (_INFO.txt) encontrado."; return; fi
        
        echo "Relatórios XenServer disponíveis:"
        i=1
        for f in "${FILES[@]}"; do echo "  [$i] $(basename "$f")"; ((i++)); done
        read -p "Selecione: " f_opt
        XEN_FILE="${FILES[$((f_opt-1))]}"
        
        log "Lendo configurações do arquivo Xen..."
        
        # Extração de Dados com grep/awk
        # Busca a interface de gerenciamento para pegar o IP principal
        X_HOSTNAME=$(grep "name-label (" "$XEN_FILE" | head -1 | awk '{print $4}')
        X_IP=$(grep -A 20 "management ( RO): true" "$XEN_FILE" | grep "IP ( RO):" | awk '{print $4}')
        X_MASK=$(grep -A 20 "management ( RO): true" "$XEN_FILE" | grep "netmask ( RO):" | awk '{print $4}')
        X_GW=$(grep -A 20 "management ( RO): true" "$XEN_FILE" | grep "gateway ( RO):" | awk '{print $4}')
        X_DNS=$(grep -A 20 "management ( RO): true" "$XEN_FILE" | grep "DNS ( RO):" | awk '{print $4}')
        
        # Fallback se não achar na seção de management
        if [ -z "$X_IP" ]; then
             X_IP=$(grep "address ( RO):" "$XEN_FILE" | head -1 | awk '{print $4}')
        fi
        
        log "--- DADOS ENCONTRADOS NO XEN ---"
        echo "Hostname : $X_HOSTNAME"
        echo "IP       : $X_IP"
        echo "Máscara  : $X_MASK"
        echo "Gateway  : $X_GW"
        echo "DNS      : $X_DNS"
        echo "--------------------------------"
        
        echo "Vamos configurar este servidor Proxmox com esses dados."
        echo "Você pode editar os valores agora ou aceitar os padrões."
        echo ""
        
        # Edição Interativa
        read -e -p "Hostname: " -i "$X_HOSTNAME" NEW_HOSTNAME
        read -e -p "Endereço IP (CIDR ex: /24 se necessário): " -i "$X_IP" NEW_IP
        read -e -p "Máscara (Netmask): " -i "$X_MASK" NEW_MASK
        read -e -p "Gateway: " -i "$X_GW" NEW_GW
        read -e -p "DNS: " -i "$X_DNS" NEW_DNS
        
        # Gerar /etc/network/interfaces
        TMP_INTERFACES="/tmp/interfaces.xen.gen"
        cat <<EOF > "$TMP_INTERFACES"
auto lo
iface lo inet loopback

iface eno1 inet manual

auto vmbr0
iface vmbr0 inet static
    address $NEW_IP
    netmask $NEW_MASK
    gateway $NEW_GW
    bridge-ports eno1
    bridge-stp off
    bridge-fd 0
    # Configuração migrada do XenServer: $X_HOSTNAME

source /etc/network/interfaces.d/*
EOF
        
        log "Arquivo de rede gerado. Abrindo para revisão..."
        read -p "Pressione ENTER para ver/editar..."
        nano "$TMP_INTERFACES"
        
        echo ""
        log "Aplicar configurações?" "WARN"
        echo "AVISO: Isso alterará o Hostname, Hosts, DNS e Rede deste servidor."
        read -p "Confirma? [y/N]: " confirm
        
        if [[ "$confirm" =~ ^[yY]$ ]]; then
            # Backup
            cp /etc/network/interfaces /etc/network/interfaces.BAK_XEN
            cp /etc/hosts /etc/hosts.BAK_XEN
            cp /etc/hostname /etc/hostname.BAK_XEN
            cp /etc/resolv.conf /etc/resolv.conf.BAK_XEN
            
            # Aplicar Rede
            cp "$TMP_INTERFACES" /etc/network/interfaces
            
            # Aplicar Hostname
            hostnamectl set-hostname "$NEW_HOSTNAME"
            echo "127.0.0.1 localhost.localdomain localhost" > /etc/hosts
            echo "$NEW_IP $NEW_HOSTNAME.local $NEW_HOSTNAME pve" >> /etc/hosts
            
            # Aplicar DNS
            echo "nameserver $NEW_DNS" > /etc/resolv.conf
            echo "search local" >> /etc/resolv.conf
            
            log "Configurações aplicadas com sucesso!" "SUCCESS"
            log "Para a rede surtir efeito, reinicie ou use 'ifreload -a' (cuidado com SSH)."
        else
            log "Operação cancelada."
        fi
        rm -f "$TMP_INTERFACES"
    else
        log "Opção inválida."
    fi
}

# --- 5. OTIMIZAÇÃO ---

optimize_proxmox() {
    clear
    log "==============================================="
    log "   PROXMOX PERFORMANCE WIZARD"
    log "==============================================="
    
    echo ""
    log "[1] Corrigir Repositórios (Remover Enterprise / Adicionar No-Subscription)"
    read -p "Aplicar? [y/N]: " repo_opt
    if [[ "$repo_opt" =~ ^[yY]$ ]]; then
        sed -i "s/^deb/#deb/g" /etc/apt/sources.list.d/pve-enterprise.list
        echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > /etc/apt/sources.list.d/pve-no-subscription.list
        apt update
        log "Repositórios atualizados." "SUCCESS"
    fi
    
    echo ""
    log "[2] Otimizar Uso de RAM (Swappiness = 10)"
    read -p "Aplicar? [y/N]: " swap_opt
    if [[ "$swap_opt" =~ ^[yY]$ ]]; then
        sysctl vm.swappiness=10
        echo "vm.swappiness=10" > /etc/sysctl.d/99-swappiness.conf
        log "Swappiness ajustado para 10." "SUCCESS"
    fi
    
    echo ""
    log "[3] CPU Governor 'Performance'"
    read -p "Aplicar? [y/N]: " cpu_opt
    if [[ "$cpu_opt" =~ ^[yY]$ ]]; then
        apt install -y linux-cpupower
        cpupower frequency-set -g performance
        echo "GOVERNOR=\"performance\"" > /etc/default/cpufrequtils
        systemctl disable ondemand
        log "CPU definida para Performance." "SUCCESS"
    fi
    
    log "Otimização concluída."
    read -p "Enter para voltar..."
}

# --- 6. LXC GIT BUILDER (V2.3) ---

create_lxc_git() {
    log "--- CRIADOR DE LXC DEV (MULTI-STACK) ---"
    
    read -p "ID do Container [ex: 200]: " CTID
    read -p "Hostname [ex: dev-server]: " CTHOST
    read -p "Senha do Root (SSH): " CTPASS
    read -p "Deseja habilitar e configurar o acesso SSH para root? [y/N]: " enable_ssh
    read -p "URL do Git [https://...]: " GIT_URL
    
    log "Buscando templates..."
    pveam update
    mapfile -t TEMPLATES < <(pveam available | grep "debian\|ubuntu" | awk '{print $2}' | sort -r | head -n 5)
    
    echo "Templates sugeridos:"
    i=1
    for t in "${TEMPLATES[@]}"; do echo "  [$i] $t"; ((i++)); done
    read -p "Escolha o template [1]: " t_opt; t_opt=${t_opt:-1}
    TEMPLATE="${TEMPLATES[$((t_opt-1))]}"
    
    if ! pveam list local | grep -q "$TEMPLATE"; then
        pveam download local "$TEMPLATE"
    fi
    
    log "Selecione o Storage:"
    mapfile -t STORAGES < <(pvesm status -content rootdir -enabled | awk 'NR>1 {print $1}')
    i=1; for s in "${STORAGES[@]}"; do echo "  [$i] $s"; ((i++)); done
    read -p "Opção: " s_opt
    TARGET_STORAGE="${STORAGES[$((s_opt-1))]}"
    
    log "Criando Container LXC..."
    pct create $CTID "local:vztmpl/$(basename "$TEMPLATE")" \
        --hostname "$CTHOST" --password "$CTPASS" \
        --storage "$TARGET_STORAGE" --rootfs 10 \
        --cores $(nproc) --memory 2048 --swap 512 \
        --net0 name=eth0,bridge=vmbr0,ip=dhcp,type=veth \
        --features nesting=1,keyctl=1 \
        --onboot 1 \
        --start 1
        
    log "Aguardando rede..."
    sleep 8
    
    log "Atualizando sistema..."
    # Configura ambiente para evitar erros de locale
    CMD_PREFIX="export DEBIAN_FRONTEND=noninteractive && export LC_ALL=C"
    pct exec $CTID -- bash -c "$CMD_PREFIX && apt-get update"
    pct exec $CTID -- bash -c "$CMD_PREFIX && apt-get install -y git curl build-essential"
    
    if [[ "$enable_ssh" =~ ^[yY]$ ]]; then
        pct exec $CTID -- bash -c "$CMD_PREFIX && apt-get install -y openssh-server"
        pct exec $CTID -- sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
        pct exec $CTID -- systemctl enable ssh
        pct exec $CTID -- systemctl restart ssh
        SSH_STATUS="Habilitado"
    else
        SSH_STATUS="Desabilitado"
    fi
    
    log "Clonando projeto..."
    pct exec $CTID -- git clone "$GIT_URL" "/var/www/project"
    
    echo ""
    log "STACKS PARA INSTALAR:"
    echo "  [1] NodeJS (LTS)    [5] PHP (Full)"
    echo "  [2] Python 3 + Pip  [6] Docker"
    echo "  [3] Nginx           [7] Rust"
    echo "  [4] Apache          [8] CMake"
    read -p "Seleção (ex: 1 3 6): " stack_sel
    
    for opt in $stack_sel; do
        case $opt in
            1) pct exec $CTID -- bash -c "curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && apt-get install -y nodejs" ;;
            2) pct exec $CTID -- bash -c "$CMD_PREFIX && apt-get install -y python3 python3-pip python3-venv" ;;
            3) pct exec $CTID -- bash -c "$CMD_PREFIX && apt-get install -y nginx" ;;
            4) pct exec $CTID -- bash -c "$CMD_PREFIX && apt-get install -y apache2" ;;
            5) pct exec $CTID -- bash -c "$CMD_PREFIX && apt-get install -y php php-cli php-fpm php-common php-mysql php-curl" ;;
            6) pct exec $CTID -- bash -c "curl -fsSL https://get.docker.com | sh" ;;
            7) pct exec $CTID -- bash -c "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y" ;;
            8) pct exec $CTID -- bash -c "$CMD_PREFIX && apt-get install -y cmake make g++" ;;
        esac
    done
    
    CT_IP=$(pct exec $CTID -- hostname -I | awk '{print $1}')
    clear
    log "LXC CRIADO: $CT_IP ($CTHOST) | SSH: $SSH_STATUS" "SUCCESS"
    read -p "Enter..."
}

# --- 7. AUDITORIA COMPLETA ---

run_audit() {
    detect_storage "DESTINO DA AUDITORIA:"
    AUDIT_DIR="$WORK_DIR/AUDITORIA_${HOSTNAME}_${DATE_NOW}"
    mkdir -p "$AUDIT_DIR"
    log "Auditando..."
    
    mkdir -p "$AUDIT_DIR/HOST_CONFIGS/etc_network"
    mkdir -p "$AUDIT_DIR/HOST_CONFIGS/etc_pve"
    
    cp /etc/network/interfaces "$AUDIT_DIR/HOST_CONFIGS/etc_network/" 2>/dev/null
    cp /etc/hosts "$AUDIT_DIR/HOST_CONFIGS/" 2>/dev/null
    cp /etc/pve/storage.cfg "$AUDIT_DIR/HOST_CONFIGS/etc_pve/" 2>/dev/null
    cp /etc/pve/user.cfg "$AUDIT_DIR/HOST_CONFIGS/etc_pve/" 2>/dev/null
    
    pveversion -v > "$AUDIT_DIR/HOST_CONFIGS/pve_version.txt"
    lsblk > "$AUDIT_DIR/HOST_CONFIGS/disk_layout.txt"
    ip addr > "$AUDIT_DIR/HOST_CONFIGS/network_current_state.txt"
    
    tar -czf "$AUDIT_DIR/HOST_BKP_${HOSTNAME}.tar.gz" -C "$AUDIT_DIR/HOST_CONFIGS" .
    rm -rf "$AUDIT_DIR/HOST_CONFIGS"
    
    mapfile -t VMS < <(qm list | awk 'NR>1 {print $1}')
    for vmid in "${VMS[@]}"; do
        vmname=$(qm config $vmid | grep "name:" | awk '{print $2}')
        [ -z "$vmname" ] && vmname="VM_$vmid"
        REPORT_FILE="$AUDIT_DIR/VM_${vmid}_${vmname}.txt"
        echo "=== RELATÓRIO: $vmname ===" > "$REPORT_FILE"
        qm config $vmid >> "$REPORT_FILE"
    done
    log "Auditoria salva em $AUDIT_DIR" "SUCCESS"
}

# --- 8. GERENCIAR SNAPSHOTS ---

manage_snapshots() {
    log "--- SNAPSHOTS ---"
    qm list
    read -p "ID da VM: " vmid
    if ! qm status $vmid &>/dev/null; then log "VM não encontrada." "ERROR"; return; fi
    
    echo "  [1] CRIAR  [2] RESTAURAR  [3] DELETAR"
    read -p "Ação: " action
    case $action in
        1)
            read -p "Nome: " name
            read -p "Salvar RAM? [y/N]: " ram
            if [[ "$ram" =~ ^[yY]$ ]]; then qm snapshot $vmid "$name" --vmstate 1; else qm snapshot $vmid "$name"; fi
            log "Criado." ;;
        2)
            read -p "Nome: " name
            qm rollback $vmid "$name"
            log "Restaurado." ;;
        3)
            read -p "Nome: " name
            qm delsnapshot $vmid "$name"
            log "Deletado." ;;
    esac
}

# --- MENU PRINCIPAL ---

show_menu() {
    clear
    log "==============================================="
    log "   PROXMOX MASTER SUITE v2.4 (HOST: $HOSTNAME)"
    log "==============================================="
    echo "  [1] EXPORTAR VMs (Backup)"
    echo "  [2] IMPORTAR VMs (Restore)"
    echo "  [3] EXPORTAR Config Host"
    echo "  [4] IMPORTAR Config Host (Xen/Proxmox)"
    echo "  [5] PROXMOX OPTIMIZER"
    echo "  [6] CRIAR LXC DEV (Git/Stack)"
    echo "  [7] AUDITORIA COMPLETA"
    echo "  [8] GERENCIAR SNAPSHOTS"
    echo "  [9] SAIR"
    echo ""
    read -p "Opção: " opt
    case $opt in
        1) run_export ;;
        2) run_import ;;
        3) export_host_config ;;
        4) import_host_config ;;
        5) optimize_proxmox ;;
        6) create_lxc_git ;;
        7) run_audit ;;
        8) manage_snapshots ;;
        9) exit 0 ;;
        *) log "Inválido."; sleep 1; show_menu ;;
    esac
    read -p "Enter para menu..."
    show_menu
}

if [ "$EUID" -ne 0 ]; then echo "Root requerido."; exit 1; fi
show_menu