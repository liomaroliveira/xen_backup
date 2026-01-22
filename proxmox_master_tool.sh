#!/bin/bash
# ============================================================
# PROXMOX MASTER TOOL - SUITE V2.0
# Gerenciamento, Backup, Restore, Auditoria, Otimização e LXC
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
    
    # Seleção de VMs
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
        clean_vmname=$(echo "$vmname" | tr -dc '[:alnum:]\-\_') # Sanitize name
        
        echo ""
        log ">>> Exportando $idx/$total: $vmid ($vmname)"
        
        # Executa vzdump
        # Captura o nome do arquivo gerado através do stdout se possível, ou busca o mais recente
        vzdump $vmid --dumpdir "$WORK_DIR" --mode $BKP_MODE --compress zstd
        
        if [ $? -eq 0 ]; then
            # RENOMEAR ARQUIVO PARA INCLUIR NOME DA VM
            # Busca o arquivo mais recente criado nos últimos 2 minutos que contenha o ID
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

# --- 4. CONFIGURAÇÕES DO HOST (EXPORT/IMPORT) ---

export_host_config() {
    detect_storage "DESTINO PARA EXPORTAR CONFIGS DO HOST:"
    EXPORT_PATH="$WORK_DIR/HOST_CONFIG_${HOSTNAME}_${DATE_NOW}.tar.gz"
    
    log "Coletando configurações..."
    TMP_DIR="/tmp/pve_export_conf_$$"
    mkdir -p "$TMP_DIR/etc_network" "$TMP_DIR/etc_pve"
    
    # Arquivos críticos
    cp /etc/network/interfaces "$TMP_DIR/etc_network/" 2>/dev/null
    cp /etc/hosts "$TMP_DIR/" 2>/dev/null
    cp /etc/resolv.conf "$TMP_DIR/" 2>/dev/null
    cp /etc/pve/storage.cfg "$TMP_DIR/etc_pve/" 2>/dev/null
    cp /etc/pve/user.cfg "$TMP_DIR/etc_pve/" 2>/dev/null
    
    # Auditoria extra
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
    log "Você verá a configuração importada e poderá editá-la antes de aplicar."
    read -p "Pressione ENTER para revisar a REDE (/etc/network/interfaces)..."
    
    # Edição Interativa
    nano "$TMP_IMPORT/etc_network/interfaces"
    
    log "--- Comparação de Rede ---"
    diff /etc/network/interfaces "$TMP_IMPORT/etc_network/interfaces" || echo "Diferenças encontradas (acima)."
    
    echo ""
    log "Deseja aplicar esta configuração de rede?" "WARN"
    log "[1] Sim, aplicar e reiniciar rede (ifreload)"
    log "[2] Sim, aplicar mas NÃO reiniciar (reboot manual necessário)"
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
    
    # Storage e Users (Cópia direta com backup)
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

# --- 5. OTIMIZAÇÃO (WIZARD) ---

optimize_proxmox() {
    clear
    log "==============================================="
    log "   PROXMOX PERFORMANCE WIZARD"
    log "==============================================="
    
    # 1. Repositórios
    echo ""
    log "[1] Corrigir Repositórios (Remover Enterprise / Adicionar No-Subscription)"
    read -p "Aplicar? [y/N]: " repo_opt
    if [[ "$repo_opt" =~ ^[yY]$ ]]; then
        sed -i "s/^deb/#deb/g" /etc/apt/sources.list.d/pve-enterprise.list
        echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > /etc/apt/sources.list.d/pve-no-subscription.list
        apt update
        log "Repositórios atualizados." "SUCCESS"
    fi
    
    # 2. Swappiness
    echo ""
    log "[2] Otimizar Uso de RAM (Swappiness)"
    log "Padrão: 60 (Usa swap cedo). Recomendado Servidor: 10 ou 1."
    read -p "Definir swappiness=10? [y/N]: " swap_opt
    if [[ "$swap_opt" =~ ^[yY]$ ]]; then
        sysctl vm.swappiness=10
        echo "vm.swappiness=10" > /etc/sysctl.d/99-swappiness.conf
        log "Swappiness ajustado para 10." "SUCCESS"
    fi
    
    # 3. CPU Governor
    echo ""
    log "[3] CPU Governor 'Performance'"
    log "Força a CPU a trabalhar no clock máximo (evita lag de scaling)."
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

# --- 6. LXC GIT BUILDER ---

create_lxc_git() {
    log "--- CRIADOR DE LXC VIA GIT ---"
    
    # Input Básico
    read -p "ID do Container [ex: 200]: " CTID
    read -p "Hostname [ex: web-app]: " CTHOST
    read -p "Senha do Root: " CTPASS
    read -p "URL do Git [https://...]: " GIT_URL
    
    # Seleção de Template
    log "Buscando templates em local:vztmpl..."
    pveam update
    mapfile -t TEMPLATES < <(pveam available | grep "debian\|ubuntu" | awk '{print $2}' | sort -r | head -n 5)
    
    echo "Templates sugeridos:"
    i=1
    for t in "${TEMPLATES[@]}"; do echo "  [$i] $t"; ((i++)); done
    read -p "Escolha o template [1]: " t_opt; t_opt=${t_opt:-1}
    TEMPLATE="${TEMPLATES[$((t_opt-1))]}"
    
    # Download se necessário
    if ! pveam list local | grep -q "$TEMPLATE"; then
        log "Baixando template $TEMPLATE..."
        pveam download local "$TEMPLATE"
    fi
    
    # Seleção Storage
    log "Selecione o Storage para o disco do Container:"
    mapfile -t STORAGES < <(pvesm status -content rootdir -enabled | awk 'NR>1 {print $1}')
    i=1; for s in "${STORAGES[@]}"; do echo "  [$i] $s"; ((i++)); done
    read -p "Opção: " s_opt
    TARGET_STORAGE="${STORAGES[$((s_opt-1))]}"
    
    # Criação Otimizada
    log "Criando Container LXC Otimizado..."
    # Nesting=1 (Permite Docker dentro), Cores=Host (Performance), Swap=512
    pct create $CTID "local:vztmpl/$(basename "$TEMPLATE")" \
        --hostname "$CTHOST" --password "$CTPASS" \
        --storage "$TARGET_STORAGE" --rootfs 8 \
        --cores $(nproc) --memory 2048 --swap 512 \
        --net0 name=eth0,bridge=vmbr0,ip=dhcp,type=veth \
        --features nesting=1 \
        --onboot 1 \
        --start 1
        
    log "Container criado e iniciado. Aguardando rede..."
    sleep 10
    
    # Instalação via pct exec
    log "Atualizando e instalando Git..."
    pct exec $CTID -- apt-get update
    pct exec $CTID -- apt-get install -y git curl build-essential
    
    log "Clonando repositório..."
    pct exec $CTID -- git clone "$GIT_URL" /var/www/project
    
    # Stack Helper
    echo ""
    log "Deseja instalar uma stack de linguagem?"
    echo "  [1] NodeJS (LTS)"
    echo "  [2] Python 3 + Pip"
    echo "  [3] PHP + Apache"
    echo "  [0] Nenhuma (Apenas Git)"
    read -p "Opção: " stack_opt
    
    case $stack_opt in
        1) pct exec $CTID -- bash -c "curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - && apt-get install -y nodejs" ;;
        2) pct exec $CTID -- apt-get install -y python3 python3-pip python3-venv ;;
        3) pct exec $CTID -- apt-get install -y php apache2 libapache2-mod-php ;;
    esac
    
    log "LXC $CTID Configurado com sucesso!" "SUCCESS"
    log "Projeto clonado em /var/www/project dentro do container."
}

# --- MENU PRINCIPAL ---

show_menu() {
    clear
    log "==============================================="
    log "   PROXMOX MASTER SUITE v2.0 (HOST: $HOSTNAME)"
    log "==============================================="
    echo "  [1] EXPORTAR VMs (Backup com Nome da VM)"
    echo "  [2] IMPORTAR VMs (Restaurar Backup)"
    echo "  [3] EXPORTAR Configurações do Host"
    echo "  [4] IMPORTAR Configurações do Host (Interativo)"
    echo "  [5] PROXMOX OPTIMIZER (Wizard de Performance)"
    echo "  [6] CRIAR LXC via GIT (Auto-Install)"
    echo "  [7] AUDITORIA / SNAPSHOTS"
    echo "  [8] SAIR"
    echo ""
    read -p "Opção: " opt
    case $opt in
        1) run_export ;;
        2) run_import ;;
        3) export_host_config ;;
        4) import_host_config ;;
        5) optimize_proxmox ;;
        6) create_lxc_git ;;
        7) 
            echo "[1] Auditoria Completa  [2] Gerenciar Snapshots"
            read -p "Sub-opção: " sub; [ "$sub" == "1" ] && detect_storage "DESTINO:" && run_audit; [ "$sub" == "2" ] && manage_snapshots
            ;;
        8) exit 0 ;;
        *) log "Inválido."; sleep 1; show_menu ;;
    esac
    read -p "Enter para menu..."
    show_menu
}

if [ "$EUID" -ne 0 ]; then echo "Root requerido."; exit 1; fi
show_menu