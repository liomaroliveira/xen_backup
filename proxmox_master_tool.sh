#!/bin/bash
# ============================================================
# PROXMOX MASTER SUITE V2.2
# Funcionalidades: Backup, Restore, Audit, Snapshots & LXC Dev Suite
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

# --- 4. CONFIGURAÇÕES DO HOST ---

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
    detect_storage "ORIGEM DAS CONFIGURAÇÕES DO HOST:"
    mapfile -t FILES < <(find "$WORK_DIR" -name "HOST_CONFIG_*.tar.gz" | sort)
    
    if [ ${#FILES[@]} -eq 0 ]; then log "Nenhum arquivo de config encontrado."; return; fi
    
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
    
    log "--- Comparação de Rede ---"
    diff /etc/network/interfaces "$TMP_IMPORT/etc_network/interfaces" || echo "Diferenças encontradas (acima)."
    
    echo ""
    log "Deseja aplicar esta configuração de rede?" "WARN"
    log "[1] Sim, aplicar e reiniciar rede (ifreload)"
    log "[2] Sim, aplicar mas NÃO reiniciar"
    log "[3] Não aplicar rede"
    read -p "Opção: " net_opt
    
    if [ "$net_opt" == "1" ] || [ "$net_opt" == "2" ]; then
        cp /etc/network/interfaces /etc/network/interfaces.BAK_$(date +%s)
        cp "$TMP_IMPORT/etc_network/interfaces" /etc/network/interfaces
        log "Arquivo de interfaces atualizado." "SUCCESS"
        if [ "$net_opt" == "1" ]; then
            log "Reiniciando serviços de rede..."
            ifreload -a
        fi
    fi
    
    read -p "Deseja importar Storage e Usuários (/etc/pve/*)? [y/N]: " pve_opt
    if [[ "$pve_opt" =~ ^[yY]$ ]]; then
        cp /etc/pve/storage.cfg /etc/pve/storage.cfg.BAK
        cp "$TMP_IMPORT/etc_pve/storage.cfg" /etc/pve/storage.cfg
        cp "$TMP_IMPORT/etc_pve/user.cfg" /etc/pve/user.cfg
        log "Storages e Usuários atualizados." "SUCCESS"
    fi
    rm -rf "$TMP_IMPORT"
    log "Importação finalizada."
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

# --- 6. LXC GIT BUILDER (V2.2 - MULTI STACK) ---

create_lxc_git() {
    log "--- CRIADOR DE LXC DEV (MULTI-STACK) ---"
    
    read -p "ID do Container [ex: 200]: " CTID
    read -p "Hostname [ex: dev-server]: " CTHOST
    read -p "Senha do Root (SSH): " CTPASS
    read -p "URL do Git [https://...]: " GIT_URL
    
    log "Buscando templates em local:vztmpl..."
    pveam update
    mapfile -t TEMPLATES < <(pveam available | grep "debian\|ubuntu" | awk '{print $2}' | sort -r | head -n 5)
    
    echo "Templates sugeridos:"
    i=1
    for t in "${TEMPLATES[@]}"; do echo "  [$i] $t"; ((i++)); done
    read -p "Escolha o template [1]: " t_opt; t_opt=${t_opt:-1}
    TEMPLATE="${TEMPLATES[$((t_opt-1))]}"
    
    if ! pveam list local | grep -q "$TEMPLATE"; then
        log "Baixando template $TEMPLATE..."
        pveam download local "$TEMPLATE"
    fi
    
    log "Selecione o Storage para o disco:"
    mapfile -t STORAGES < <(pvesm status -content rootdir -enabled | awk 'NR>1 {print $1}')
    i=1; for s in "${STORAGES[@]}"; do echo "  [$i] $s"; ((i++)); done
    read -p "Opção: " s_opt
    TARGET_STORAGE="${STORAGES[$((s_opt-1))]}"
    
    # Criação do Container
    # Adicionado keyctl=1 para Docker funcionar
    log "Criando Container LXC (Nesting=1, Keyctl=1)..."
    pct create $CTID "local:vztmpl/$(basename "$TEMPLATE")" \
        --hostname "$CTHOST" --password "$CTPASS" \
        --storage "$TARGET_STORAGE" --rootfs 10 \
        --cores $(nproc) --memory 2048 --swap 512 \
        --net0 name=eth0,bridge=vmbr0,ip=dhcp,type=veth \
        --features nesting=1,keyctl=1 \
        --onboot 1 \
        --start 1
        
    log "Container iniciado. Aguardando rede..."
    sleep 8
    
    log "Atualizando base do sistema..."
    pct exec $CTID -- apt-get update
    pct exec $CTID -- apt-get install -y git curl build-essential openssh-server
    
    # CONFIGURAÇÃO SSH (Permitir Root)
    log "Configurando SSH para permitir root..."
    pct exec $CTID -- sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
    pct exec $CTID -- systemctl enable ssh
    pct exec $CTID -- systemctl restart ssh
    
    # CLONE GIT
    log "Clonando projeto..."
    PROJECT_DIR="/var/www/project"
    pct exec $CTID -- git clone "$GIT_URL" "$PROJECT_DIR"
    
    # INSTALAÇÃO DE STACKS (MULTI-SELEÇÃO)
    echo ""
    log "SELECIONE AS STACKS PARA INSTALAR (Separadas por espaço)"
    echo "Exemplo: 1 3 5 (Instala Node, Nginx e Docker)"
    echo "----------------------------------------------"
    echo "  [1] NodeJS (LTS)"
    echo "  [2] Python 3 + Pip"
    echo "  [3] Nginx Web Server"
    echo "  [4] PHP + Apache"
    echo "  [5] Docker + Docker Compose"
    echo "  [6] Rust (Cargo)"
    echo "  [7] CMake & Make Tools"
    echo "----------------------------------------------"
    read -p "Seleção: " stack_sel
    
    for opt in $stack_sel; do
        case $opt in
            1) 
                log ">> Instalando NodeJS..."
                pct exec $CTID -- bash -c "curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && apt-get install -y nodejs" 
                ;;
            2) 
                log ">> Instalando Python 3..."
                pct exec $CTID -- apt-get install -y python3 python3-pip python3-venv 
                ;;
            3) 
                log ">> Instalando Nginx..."
                pct exec $CTID -- apt-get install -y nginx 
                ;;
            4) 
                log ">> Instalando PHP/Apache..."
                pct exec $CTID -- apt-get install -y php apache2 libapache2-mod-php 
                ;;
            5) 
                log ">> Instalando Docker..."
                pct exec $CTID -- bash -c "curl -fsSL https://get.docker.com | sh" 
                ;;
            6) 
                log ">> Instalando Rust..."
                pct exec $CTID -- bash -c "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y" 
                ;;
            7) 
                log ">> Instalando Build Tools..."
                pct exec $CTID -- apt-get install -y cmake make g++ 
                ;;
        esac
    done
    
    # RELATÓRIO FINAL
    CT_IP=$(pct exec $CTID -- hostname -I | awk '{print $1}')
    clear
    log "==============================================="
    log "   LXC DEPLOYMENT FINALIZADO" "SUCCESS"
    log "==============================================="
    echo "  Container ID : $CTID"
    echo "  Hostname     : $CTHOST"
    echo "  IP Address   : $CT_IP (DHCP)"
    echo "  Usuário      : root"
    echo "  Senha        : $CTPASS"
    echo "  SSH Acesso   : ssh root@$CT_IP"
    echo "  Projeto Git  : $PROJECT_DIR"
    echo "==============================================="
    read -p "Pressione ENTER para voltar..."
}

# --- 7. AUDITORIA COMPLETA ---

run_audit() {
    detect_storage "SELECIONE O DESTINO DA AUDITORIA:"
    AUDIT_DIR="$WORK_DIR/AUDITORIA_${HOSTNAME}_${DATE_NOW}"
    mkdir -p "$AUDIT_DIR"
    log "Iniciando Auditoria em: $AUDIT_DIR"
    
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
    
    log "    [OK] Configurações do Host salvas." "SUCCESS"
    
    log ">>> Gerando relatórios das VMs..."
    mapfile -t VMS < <(qm list | awk 'NR>1 {print $1}')
    
    for vmid in "${VMS[@]}"; do
        vmname=$(qm config $vmid | grep "name:" | awk '{print $2}')
        [ -z "$vmname" ] && vmname="VM_$vmid"
        REPORT_FILE="$AUDIT_DIR/VM_${vmid}_${vmname}.txt"
        
        echo "=== RELATÓRIO TÉCNICO: $vmname ($vmid) ===" > "$REPORT_FILE"
        echo "Data: $DATE_NOW" >> "$REPORT_FILE"
        echo "-------------------------------------------" >> "$REPORT_FILE"
        echo "STATUS:" >> "$REPORT_FILE"; qm status $vmid >> "$REPORT_FILE"
        echo "CONFIG:" >> "$REPORT_FILE"; qm config $vmid >> "$REPORT_FILE"
        echo "DISCOS:" >> "$REPORT_FILE"; qm config $vmid | grep -E "scsi|sata|ide|virtio" >> "$REPORT_FILE"
        echo "REDE:" >> "$REPORT_FILE"; qm config $vmid | grep "net" >> "$REPORT_FILE"
        log "    [OK] Auditado: $vmname"
    done
    log "Auditoria Concluída." "SUCCESS"
}

# --- 8. GERENCIAR SNAPSHOTS ---

manage_snapshots() {
    log "--- GERENCIADOR DE SNAPSHOTS ---"
    qm list
    echo "-------------------------------------"
    read -p "Digite o ID da VM alvo: " vmid
    
    if ! qm status $vmid &>/dev/null; then log "VM não encontrada." "ERROR"; return; fi
    
    echo ""
    echo "Snapshots atuais:"
    qm listsnapshot $vmid
    echo "-------------------------------------"
    echo "  [1] CRIAR Snapshot"
    echo "  [2] RESTAURAR (Rollback)"
    echo "  [3] DELETAR Snapshot"
    read -p "Ação: " action
    
    case $action in
        1)
            read -p "Nome do Snapshot (sem espaços): " snap_name
            read -p "Incluir Estado da RAM? [y/N]: " ram_opt
            if [[ "$ram_opt" =~ ^[yY]$ ]]; then
                qm snapshot $vmid "$snap_name" --vmstate 1
            else
                qm snapshot $vmid "$snap_name"
            fi
            log "Snapshot '$snap_name' criado." "SUCCESS"
            ;;
        2)
            read -p "Nome do Snapshot para restaurar: " snap_name
            qm rollback $vmid "$snap_name"
            log "Rollback concluído." "SUCCESS"
            ;;
        3)
            read -p "Nome do Snapshot para APAGAR: " snap_name
            qm delsnapshot $vmid "$snap_name"
            log "Snapshot apagado." "SUCCESS"
            ;;
        *) log "Opção inválida." "ERROR" ;;
    esac
}

# --- MENU PRINCIPAL ---

show_menu() {
    clear
    log "==============================================="
    log "   PROXMOX MASTER SUITE v2.2 (HOST: $HOSTNAME)"
    log "==============================================="
    echo "  [1] EXPORTAR VMs (Backup com Nome da VM)"
    echo "  [2] IMPORTAR VMs (Restaurar Backup)"
    echo "  [3] EXPORTAR Configurações do Host"
    echo "  [4] IMPORTAR Configurações do Host (Interativo)"
    echo "  [5] PROXMOX OPTIMIZER (Wizard de Performance)"
    echo "  [6] CRIAR LXC via GIT (Multi-Stack Dev Env)"
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