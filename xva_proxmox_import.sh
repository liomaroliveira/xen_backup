#!/bin/bash
# ============================================================
# MIGRATOR PRO: XENSERVER TO PROXMOX (IMPORT & CONVERT)
# Versão: 1.6 (Smart Temp Storage Selection)
# ============================================================

# --- CONFIGURAÇÕES ---
LOG_FILE="/var/log/xva_import_$(date +%Y%m%d_%H%M).log"
TEMP_DIR_ROOT="/var/tmp/xva_conversion"

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
}

check_dependencies() {
    log "Verificando dependências..."
    if ! command -v xva-img &> /dev/null; then
        log "Instalando xva-img e dependências..." "WARN"
        apt-get update -qq
        apt-get install -y cmake g++ libssl-dev make git pv libxxhash-dev coreutils -qq
        
        cd /tmp
        rm -rf xva-img
        git clone https://github.com/eriklax/xva-img.git
        cd xva-img
        cmake .
        make
        cp xva-img /usr/local/bin/
        chmod +x /usr/local/bin/xva-img
    fi
    if ! command -v pv &> /dev/null; then apt-get install -y pv -qq; fi
    if ! command -v numfmt &> /dev/null; then apt-get install -y coreutils -qq; fi
    log "Dependências OK." "SUCCESS"
}

configure_bridge_vlan() {
    local bridge=$1
    if grep -q "iface $bridge" /etc/network/interfaces && grep -q "bridge-vlan-aware yes" /etc/network/interfaces; then
        return 0
    fi
    log "AVISO: Bridge '$bridge' não é VLAN-Aware." "WARN"
    read -p "Deseja ativar VLAN-Aware em '$bridge'? (Recarrega rede) [y/N]: " fix_vlan
    if [[ "$fix_vlan" =~ ^[yY]$ ]]; then
        cp /etc/network/interfaces /etc/network/interfaces.bak.$(date +%s)
        sed -i "/iface $bridge inet/a \\ \\ \\ \\ bridge-vlan-aware yes" /etc/network/interfaces
        ifreload -a
        log "Rede atualizada." "SUCCESS"
    fi
}

# --- FUNÇÕES DE FONTE ---

select_source() {
    echo ""
    log "SELECIONE A ORIGEM DO BACKUP (.xva):"
    echo "  [1] HD Externo USB (Detecção Automática)"
    echo "  [2] Diretório Local / Rede (Digitar Caminho)"
    read -p "Opção: " src_opt
    
    if [ "$src_opt" == "1" ]; then
        detect_usb
    else
        read -p "Digite o caminho completo: " custom_path
        if [ -d "$custom_path" ]; then
            MOUNT_POINT="$custom_path"
            log "Origem definida: $MOUNT_POINT" "INFO"
        else
            log "Diretório não encontrado!" "ERROR"
            exit 1
        fi
    fi
}

detect_usb() {
    log "Detectando USBs..."
    mapfile -t DISKS < <(lsblk -rn -o NAME,SIZE,TRAN,MOUNTPOINT | grep "usb" | grep -v "sda")
    [ ${#DISKS[@]} -eq 0 ] && mapfile -t DISKS < <(lsblk -rn -o NAME,SIZE,TRAN,MOUNTPOINT | grep "sd" | grep -v "sda")

    if [ ${#DISKS[@]} -eq 0 ]; then
        log "Nenhum disco USB encontrado." "ERROR"
        exit 1
    fi

    echo "------------------------------------------------"
    i=1
    for disk in "${DISKS[@]}"; do echo "[$i] /dev/$disk"; ((i++)); done
    echo "------------------------------------------------"
    read -p "Número do HD: " disk_opt
    
    SELECTED_DISK_LINE="${DISKS[$((disk_opt-1))]}"
    SELECTED_DEV="/dev/$(echo $SELECTED_DISK_LINE | awk '{print $1}')"
    MOUNT_POINT="/mnt/xva_import_usb"
    mkdir -p $MOUNT_POINT
    
    CURRENT_MOUNT=$(echo $SELECTED_DISK_LINE | awk '{print $4}')
    if [ -n "$CURRENT_MOUNT" ]; then MOUNT_POINT="$CURRENT_MOUNT"; else mount $SELECTED_DEV $MOUNT_POINT; fi
}

select_file() {
    log "Buscando arquivos .xva..."
    mapfile -t FILES < <(find "$MOUNT_POINT" -maxdepth 3 -name "*.xva" | sort)
    [ ${#FILES[@]} -eq 0 ] && { log "Nenhum arquivo .xva encontrado." "ERROR"; exit 1; }

    echo "----------------------------------------------------------------"
    printf "%-3s | %-50s | %-10s\n" "ID" "ARQUIVO" "TAMANHO"
    echo "----------------------------------------------------------------"
    i=1
    for f in "${FILES[@]}"; do
        fsize=$(ls -lh "$f" | awk '{print $5}')
        printf "%-3s | %-50s | %-10s\n" "$i" "${f##*/}" "$fsize"
        ((i++))
    done
    
    read -p "Arquivo ID: " file_opt
    XVA_FILE="${FILES[$((file_opt-1))]}"
    VM_NAME_RAW=$(basename "$XVA_FILE" .xva)
    CLEAN_NAME=$(echo "$VM_NAME_RAW" | sed -E 's/_[0-9]{4}-[0-9]{2}-[0-9]{2}.*$//' | tr '_' '-')
}

parse_audit_data() {
    SEARCH_NAME=$(echo "$CLEAN_NAME" | tr '-' '_') 
    AUDIT_FILE=$(find "$MOUNT_POINT" -name "*${SEARCH_NAME}*_INFO.txt" | head -n 1)
    
    SUGGEST_CPU=2; SUGGEST_RAM=2048; SUGGEST_MACS=(); SUGGEST_VLANS=()
    
    if [ -f "$AUDIT_FILE" ]; then
        log "Auditoria encontrada." "SUCCESS"
        CPU_READ=$(grep "VCPUs-max" "$AUDIT_FILE" | head -1 | awk '{print $NF}')
        [ -n "$CPU_READ" ] && SUGGEST_CPU=$CPU_READ
        RAM_BYTES=$(grep "memory-static-max" "$AUDIT_FILE" | head -1 | awk '{print $NF}')
        [ -n "$RAM_BYTES" ] && SUGGEST_RAM=$((RAM_BYTES / 1024 / 1024))
        
        while IFS= read -r line; do
            if [[ $line == *"[VIF:"* ]]; then vif_active="true"; mac=""; net=""; fi
            if [[ $line == *"MAC ( RO):"* ]] && [ "$vif_active" == "true" ]; then mac=$(echo $line | awk '{print $4}'); fi
            if [[ $line == *"network-name-label"* ]] && [ "$vif_active" == "true" ]; then
                net=$(echo $line | awk '{print $4}')
                if [[ $net =~ VLAN([0-9]+) ]]; then vlan="${BASH_REMATCH[1]}"; elif [[ $net =~ vlan([0-9]+) ]]; then vlan="${BASH_REMATCH[1]}"; else vlan=""; fi
                if [ -n "$mac" ]; then SUGGEST_MACS+=("$mac"); SUGGEST_VLANS+=("${vlan:-1}"); vif_active="false"; fi
            fi
        done < "$AUDIT_FILE"
    fi
}

validate_host_resources() {
    HOST_FREE_RAM=$(free -m | awk '/^Mem:/{print $7}')
    if [ "$SUGGEST_RAM" -gt "$HOST_FREE_RAM" ]; then
        log "ALERTA: Host tem pouca RAM (${HOST_FREE_RAM}MB) para esta VM (${SUGGEST_RAM}MB)." "WARN"
        read -p "Continuar? [y/N]: " force_ram; [[ ! "$force_ram" =~ ^[yY]$ ]] && exit 1
    fi
}

check_disk_space() {
    local target_dir=$1
    log "Calculando tamanho REAL do disco (extraindo metadados)..."
    
    mkdir -p "$target_dir"
    tar -xf "$XVA_FILE" -C "$target_dir" ova.xml 2>/dev/null
    
    if [ ! -f "$target_dir/ova.xml" ]; then
        log "AVISO: Não foi possível ler metadados. Estimando x2..." "WARN"
        TOTAL_REQ_BYTES=$(($(stat -c%s "$XVA_FILE") * 2))
    else
        TOTAL_REQ_BYTES=$(grep "virtual_size" "$target_dir/ova.xml" | awk -F'"' '{s+=$2} END {print s}')
        rm -f "$target_dir/ova.xml"
    fi
    
    # Verifica espaço no caminho escolhido
    AVAIL_BYTES=$(df --output=avail -B1 "$target_dir" | tail -1)
    
    REQ_GB=$((TOTAL_REQ_BYTES / 1024 / 1024 / 1024))
    AVAIL_GB=$((AVAIL_BYTES / 1024 / 1024 / 1024))
    
    log "Espaço Necessário (Expandido): ~${REQ_GB} GB"
    log "Espaço Disponível em $target_dir: ${AVAIL_GB} GB"
    
    if [ "$TOTAL_REQ_BYTES" -gt "$AVAIL_BYTES" ]; then
        log "CRITICAL: Espaço insuficiente em $target_dir!" "ERROR"
        log "A conversão falhará. Escolha um storage maior (ex: os 4TB) ou o USB."
        exit 1
    else
        log "Espaço OK. Prosseguindo." "SUCCESS"
    fi
}

configure_vm() {
    echo ""
    log "--- CONFIGURAÇÃO ---"
    
    NEXT_ID=$(pvesh get /cluster/nextid)
    read -p "ID VM [$NEXT_ID]: " VMID; VMID=${VMID:-$NEXT_ID}
    read -p "Nome [$CLEAN_NAME]: " VMNAME; VMNAME=${VMNAME:-$CLEAN_NAME}; VMNAME=$(echo "$VMNAME" | tr '_' '-')
    
    validate_host_resources
    
    # --- STORAGE DE DESTINO (ONDE A VM VAI MORAR) ---
    echo ""; log "Selecione o Storage de Destino (Onde a VM vai ficar):"
    mapfile -t STORAGES < <(pvesm status -enabled | awk 'NR>1 {print $1}')
    [ ${#STORAGES[@]} -eq 0 ] && { log "Sem storage!" "ERROR"; exit 1; }

    i=1
    for store in "${STORAGES[@]}"; do
        size_kb=$(pvesm status -storage "$store" | awk 'NR==2 {print $6}')
        size_human=$(numfmt --from-unit=1024 --to=iec $size_kb 2>/dev/null || echo "${size_kb}KB")
        type=$(pvesm status -storage "$store" | awk 'NR==2 {print $2}')
        echo "  [$i] $store (Tipo: $type | Livre: $size_human)"
        ((i++))
    done
    read -p "Opção: " store_opt; TARGET_STORAGE="${STORAGES[$((store_opt-1))]}"
    [ -z "$TARGET_STORAGE" ] && TARGET_STORAGE="local-lvm"

    # --- NOVO MENU: STORAGE TEMPORÁRIO (ONDE VAMOS TRABALHAR) ---
    echo ""; log "Selecione o Local Temporário para Conversão (.raw):"
    echo "  [1] Usar o HD Externo (Seguro - Espaço do USB)"
    echo "  [2] Partição do Sistema (Rápido - Cuidado! Apenas 100GB)"
    
    # Busca Storages que suportam arquivos (Directory/ZFS) para usar o espaço deles
    mapfile -t FILE_STORAGES < <(pvesm status -content images -enabled | awk 'NR>1 {print $1}')
    idx=3
    declare -a STORAGE_PATHS
    
    for fs_store in "${FILE_STORAGES[@]}"; do
        path=$(pvesm path "$fs_store" "$VMID" 2>/dev/null | xargs dirname 2>/dev/null)
        # Se pvesm path falhar, tenta pegar config dir
        if [ -z "$path" ]; then
             path=$(grep -A5 "^dir: $fs_store" /etc/pve/storage.cfg | grep "path" | awk '{print $2}')
        fi
        
        # Só mostra se achou um caminho válido e gravável
        if [ -n "$path" ] && [ -d "$path" ]; then
            avail=$(df -h "$path" | awk 'NR==2 {print $4}')
            echo "  [$idx] Storage Proxmox: $fs_store (Livre: $avail)"
            STORAGE_PATHS[$idx]="$path/temp_xva"
            ((idx++))
        fi
    done
    
    read -p "Opção [1]: " temp_opt
    temp_opt=${temp_opt:-1}
    
    if [ "$temp_opt" == "1" ]; then
        WORK_DIR="$MOUNT_POINT/temp_conversion"
    elif [ "$temp_opt" == "2" ]; then
        WORK_DIR="$TEMP_DIR_ROOT"
    elif [ -n "${STORAGE_PATHS[$temp_opt]}" ]; then
        WORK_DIR="${STORAGE_PATHS[$temp_opt]}"
        log "Usando storage do Proxmox: $WORK_DIR" "INFO"
    else
        log "Opção inválida. Usando USB." "WARN"
        WORK_DIR="$MOUNT_POINT/temp_conversion"
    fi
    mkdir -p "$WORK_DIR"
    
    # Valida espaço no local escolhido
    check_disk_space "$WORK_DIR"
    
    # --- REDE ---
    echo ""; log "Selecione a Bridge de Rede:"
    mapfile -t BRIDGES < <(ip -br link show type bridge | awk '{print $1}')
    i=1; for br in "${BRIDGES[@]}"; do echo "  [$i] $br"; ((i++)); done
    read -p "Opção: " br_opt; SEL_BRIDGE="${BRIDGES[$((br_opt-1))]}"
    [ -z "$SEL_BRIDGE" ] && SEL_BRIDGE="vmbr0"
    
    USE_VLAN="n"
    if [ ${#SUGGEST_VLANS[@]} -gt 0 ] && [ -n "$SEL_BRIDGE" ]; then
        log "VLANs detectadas: ${SUGGEST_VLANS[*]}"
        read -p "Deseja aplicar as Tags de VLAN? [y/N]: " vlan_opt; USE_VLAN=${vlan_opt:-n}
        [[ "$USE_VLAN" =~ ^[yY]$ ]] && configure_bridge_vlan "$SEL_BRIDGE"
    fi
}

run_import() {
    log "Criando VM $VMID..."
    if ! qm create $VMID --name "$VMNAME" --memory $SUGGEST_RAM --cores $SUGGEST_CPU --ostype l26 --scsihw virtio-scsi-pci; then
        log "Falha ao criar VM." "ERROR"; exit 1
    fi
    
    log "Configurando Rede..."
    if [ ${#SUGGEST_MACS[@]} -eq 0 ] || [ -z "$SEL_BRIDGE" ]; then
        [ -n "$SEL_BRIDGE" ] && qm set $VMID --net0 virtio,bridge=$SEL_BRIDGE
    else
        idx=0
        for mac in "${SUGGEST_MACS[@]}"; do
            vlan="${SUGGEST_VLANS[$idx]}"
            tag_cmd=""; [[ "$USE_VLAN" =~ ^[yY]$ ]] && [ -n "$vlan" ] && [ "$vlan" != "1" ] && tag_cmd=",tag=$vlan"
            qm set $VMID --net$idx virtio,bridge=$SEL_BRIDGE,macaddr=$mac$tag_cmd
            ((idx++))
        done
    fi
    
    log "Convertendo disco (pode demorar)..."
    rm -rf "$WORK_DIR/Ref"* "$WORK_DIR/disk.raw" 2>/dev/null
    tar -xf "$XVA_FILE" -C "$WORK_DIR"
    
    DISK_REF_DIR=$(du -s "$WORK_DIR"/Ref* | sort -nr | head -n 1 | awk '{print $2}')
    /usr/local/bin/xva-img -p disk-export "$DISK_REF_DIR/" "$WORK_DIR/disk.raw"
    
    if [ ! -f "$WORK_DIR/disk.raw" ]; then log "Erro crítico na conversão." "ERROR"; exit 1; fi
    
    log "Importando para $TARGET_STORAGE..."
    if ! qm importdisk $VMID "$WORK_DIR/disk.raw" $TARGET_STORAGE --format raw; then
        log "Erro na importação." "ERROR"; exit 1
    fi
    
    IMPORTED_DISK=$(qm config $VMID | grep unused | head -n 1 | awk '{print $2}')
    if [ -n "$IMPORTED_DISK" ]; then
        qm set $VMID --scsi0 $IMPORTED_DISK,ssd=1
        qm set $VMID --boot c --bootdisk scsi0
        qm set $VMID --agent 1
    fi
    
    rm -rf "$WORK_DIR/Ref"* "$WORK_DIR/disk.raw" "$WORK_DIR/ova.xml"
    log "SUCESSO! VM $VMID Importada." "SUCCESS"
}

# --- EXECUÇÃO ---
clear
log "==============================================="
log "   XEN TO PROXMOX - IMPORT WIZARD v1.6"
log "==============================================="

check_dependencies
select_source
select_file
parse_audit_data
configure_vm
run_import