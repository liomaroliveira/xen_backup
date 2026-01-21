#!/bin/bash
# ============================================================
# MIGRATOR PRO: XENSERVER TO PROXMOX (IMPORT & CONVERT)
# Versão: 1.2 (Storage Menu & Name Sanitizer)
# ============================================================

# --- CONFIGURAÇÕES ---
LOG_FILE="/var/log/xva_import_$(date +%Y%m%d_%H%M).log"
TEMP_DIR_LOCAL="/var/tmp/xva_conversion"
DEFAULT_BRIDGE="vmbr0"

# --- CORES E FORMATAÇÃO ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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
    
    if [ -n "$MOUNT_POINT" ] && mountpoint -q "$MOUNT_POINT"; then
        echo "[$(date +'%H:%M:%S')] [$level] $msg" | sed 's/\x1b\[[0-9;]*m//g' >> "$MOUNT_POINT/import_log.txt"
    fi
}

check_dependencies() {
    log "Verificando dependências..."
    if ! command -v xva-img &> /dev/null; then
        log "Ferramenta 'xva-img' não encontrada. Instalando..." "WARN"
        apt-get update -qq
        apt-get install -y cmake g++ libssl-dev make git pv libxxhash-dev -qq
        
        cd /tmp
        rm -rf xva-img
        git clone https://github.com/eriklax/xva-img.git
        cd xva-img
        cmake .
        make
        cp xva-img /usr/local/bin/
        chmod +x /usr/local/bin/xva-img
        
        if command -v xva-img &> /dev/null; then
            log "xva-img instalado com sucesso!" "SUCCESS"
        else
            log "Falha ao instalar xva-img." "ERROR"
            exit 1
        fi
    else
        log "xva-img já está instalado." "SUCCESS"
    fi
    if ! command -v pv &> /dev/null; then apt-get install -y pv -qq; fi
}

# --- FUNÇÕES DE WIZARD ---

detect_usb() {
    log "Detectando unidades USB..."
    mapfile -t DISKS < <(lsblk -rn -o NAME,SIZE,TRAN,MOUNTPOINT | grep "usb" | grep -v "sda")
    if [ ${#DISKS[@]} -eq 0 ]; then
        mapfile -t DISKS < <(lsblk -rn -o NAME,SIZE,TRAN,MOUNTPOINT | grep "sd" | grep -v "sda")
    fi

    if [ ${#DISKS[@]} -eq 0 ]; then
        log "Nenhum disco USB detectado." "ERROR"
        exit 1
    fi

    echo "------------------------------------------------"
    i=1
    for disk in "${DISKS[@]}"; do
        echo "[$i] /dev/$disk"
        ((i++))
    done
    echo "------------------------------------------------"
    read -p "Escolha o número do HD Externo: " disk_opt
    
    SELECTED_DISK_LINE="${DISKS[$((disk_opt-1))]}"
    SELECTED_DEV="/dev/$(echo $SELECTED_DISK_LINE | awk '{print $1}')"
    
    MOUNT_POINT="/mnt/xva_import_usb"
    mkdir -p $MOUNT_POINT
    
    CURRENT_MOUNT=$(echo $SELECTED_DISK_LINE | awk '{print $4}')
    if [ -n "$CURRENT_MOUNT" ]; then
        MOUNT_POINT="$CURRENT_MOUNT"
        log "Disco já montado em: $MOUNT_POINT" "INFO"
    else
        log "Montando $SELECTED_DEV em $MOUNT_POINT..."
        mount $SELECTED_DEV $MOUNT_POINT
        if [ $? -ne 0 ]; then log "Erro ao montar." "ERROR"; exit 1; fi
    fi
}

select_file() {
    log "Buscando arquivos .xva em $MOUNT_POINT..."
    mapfile -t FILES < <(find "$MOUNT_POINT" -maxdepth 2 -name "*.xva" | sort)

    if [ ${#FILES[@]} -eq 0 ]; then
        log "Nenhum arquivo .xva encontrado." "ERROR"
        exit 1
    fi

    echo "------------------------------------------------"
    printf "%-3s | %-40s | %-10s\n" "ID" "ARQUIVO" "TAMANHO"
    echo "------------------------------------------------"
    i=1
    for f in "${FILES[@]}"; do
        fname=$(basename "$f")
        fsize=$(ls -lh "$f" | awk '{print $5}')
        printf "%-3s | %-40s | %-10s\n" "$i" "${fname:0:40}" "$fsize"
        ((i++))
    done
    echo "------------------------------------------------"
    
    read -p "Selecione o arquivo para importar: " file_opt
    XVA_FILE="${FILES[$((file_opt-1))]}"
    VM_NAME_RAW=$(basename "$XVA_FILE" .xva)
    # Higienização: Remove datas e troca underscore por traço (Proxmox não aceita _)
    CLEAN_NAME=$(echo "$VM_NAME_RAW" | sed -E 's/_[0-9]{4}-[0-9]{2}-[0-9]{2}.*$//' | tr '_' '-')
}

parse_audit_data() {
    log "Procurando dados de auditoria..."
    # Busca aproximada pelo nome (ignorando traços/underscores para achar o arquivo)
    SEARCH_NAME=$(echo "$CLEAN_NAME" | tr '-' '_') 
    AUDIT_FILE=$(find "$MOUNT_POINT" -name "*${SEARCH_NAME}*_INFO.txt" | head -n 1)
    
    if [ -z "$AUDIT_FILE" ]; then
        # Tenta buscar pelo nome original RAW se falhar
        AUDIT_FILE=$(find "$MOUNT_POINT" -name "*${VM_NAME_RAW}*_INFO.txt" | head -n 1)
    fi
    
    SUGGEST_CPU=2
    SUGGEST_RAM=2048
    SUGGEST_MACS=()
    SUGGEST_VLANS=()
    
    if [ -f "$AUDIT_FILE" ]; then
        log "Arquivo de auditoria encontrado: $(basename "$AUDIT_FILE")" "SUCCESS"
        
        CPU_READ=$(grep "VCPUs-max" "$AUDIT_FILE" | head -1 | awk '{print $NF}')
        if [ -n "$CPU_READ" ]; then SUGGEST_CPU=$CPU_READ; fi
        
        RAM_BYTES=$(grep "memory-static-max" "$AUDIT_FILE" | head -1 | awk '{print $NF}')
        if [ -n "$RAM_BYTES" ]; then SUGGEST_RAM=$((RAM_BYTES / 1024 / 1024)); fi
        
        while IFS= read -r line; do
            if [[ $line == *"[VIF:"* ]]; then
                current_vif="true"
                current_mac=""
                current_net=""
            fi
            if [[ $line == *"MAC ( RO):"* ]] && [ "$current_vif" == "true" ]; then
                current_mac=$(echo $line | awk '{print $4}')
            fi
            if [[ $line == *"network-name-label"* ]] && [ "$current_vif" == "true" ]; then
                current_net=$(echo $line | awk '{print $4}')
                vlan_id=""
                if [[ $current_net =~ VLAN([0-9]+) ]]; then vlan_id="${BASH_REMATCH[1]}";
                elif [[ $current_net =~ vlan([0-9]+) ]]; then vlan_id="${BASH_REMATCH[1]}"; fi
                
                if [ -n "$current_mac" ]; then
                    SUGGEST_MACS+=("$current_mac")
                    SUGGEST_VLANS+=("${vlan_id:-1}")
                    current_vif="false"
                fi
            fi
        done < "$AUDIT_FILE"
    else
        log "AVISO: Auditoria não encontrada. Usando padrão." "WARN"
    fi
}

configure_vm() {
    echo ""
    log "--- CONFIGURAÇÃO DA NOVA VM ---"
    
    NEXT_ID=$(pvesh get /cluster/nextid)
    read -p "ID da Nova VM [$NEXT_ID]: " VMID
    VMID=${VMID:-$NEXT_ID}
    
    read -p "Nome da VM (Sem '_') [$CLEAN_NAME]: " VMNAME
    VMNAME=${VMNAME:-$CLEAN_NAME}
    # Força higienização novamente caso usuário tenha digitado com _
    VMNAME=$(echo "$VMNAME" | tr '_' '-')
    
    echo "Hardware: ${SUGGEST_CPU} vCPUs / ${SUGGEST_RAM} MB RAM"
    read -p "Manter? [S/n]: " hw_conf
    if [[ "$hw_conf" =~ ^[nN]$ ]]; then
        read -p "Novos vCPUs: " SUGGEST_CPU
        read -p "Nova RAM (MB): " SUGGEST_RAM
    fi
    
    # --- NOVO MENU DE STORAGE ---
    echo ""
    log "Selecione o Storage de Destino:"
    mapfile -t STORAGES < <(pvesm status -content images | awk 'NR>1 {print $1}')
    
    if [ ${#STORAGES[@]} -eq 0 ]; then
        log "Nenhum storage disponível!" "ERROR"
        exit 1
    fi

    i=1
    for store in "${STORAGES[@]}"; do
        # Pega info extra (Tipo/Livre)
        info=$(pvesm status -storage "$store" | awk 'NR==2 {print $2 " " $4 " free"}')
        echo "[$i] $store ($info)"
        ((i++))
    done
    
    read -p "Número do Storage: " store_opt
    TARGET_STORAGE="${STORAGES[$((store_opt-1))]}"
    
    if [ -z "$TARGET_STORAGE" ]; then
        log "Opção inválida. Usando local-lvm." "WARN"
        TARGET_STORAGE="local-lvm"
    fi
    log ">> Storage selecionado: $TARGET_STORAGE" "INFO"

    # Conversão Temporária
    echo ""
    log "Local para Conversão Temporária (.raw):"
    log "[1] Local ($TEMP_DIR_LOCAL) - Rápido"
    log "[2] USB ($MOUNT_POINT) - Lento (Economiza espaço)"
    read -p "Escolha [1]: " temp_opt
    temp_opt=${temp_opt:-1}
    
    if [ "$temp_opt" == "1" ]; then
        WORK_DIR="$TEMP_DIR_LOCAL"
    else
        WORK_DIR="$MOUNT_POINT/temp_conversion"
    fi
    mkdir -p "$WORK_DIR"
}

run_import() {
    log "Iniciando processo..."
    
    # 1. Criar VM
    log "Criando VM $VMID ($VMNAME)..."
    # Captura erro de criação
    if ! qm create $VMID --name "$VMNAME" --memory $SUGGEST_RAM --cores $SUGGEST_CPU --ostype l26 --scsihw virtio-scsi-pci; then
        log "CRITICAL: Falha ao criar a VM. Verifique se o ID já existe ou o nome é inválido." "ERROR"
        exit 1
    fi
    
    # 2. Configurar Rede
    log "Configurando Interfaces de Rede..."
    if [ ${#SUGGEST_MACS[@]} -eq 0 ]; then
        qm set $VMID --net0 virtio,bridge=$DEFAULT_BRIDGE
    else
        idx=0
        for mac in "${SUGGEST_MACS[@]}"; do
            vlan="${SUGGEST_VLANS[$idx]}"
            tag_cmd=""
            if [ -n "$vlan" ] && [ "$vlan" != "1" ]; then
                tag_cmd=",tag=$vlan"
            fi
            log "  -> net$idx: MAC=$mac VLAN=$vlan"
            qm set $VMID --net$idx virtio,bridge=$DEFAULT_BRIDGE,macaddr=$mac$tag_cmd
            ((idx++))
        done
    fi
    
    # 3. Conversão
    log "Extraindo XVA (Aguarde)..."
    rm -rf "$WORK_DIR/Ref"* 2>/dev/null
    rm -f "$WORK_DIR/disk.raw" 2>/dev/null
    
    tar -xf "$XVA_FILE" -C "$WORK_DIR"
    DISK_REF_DIR=$(du -s "$WORK_DIR"/Ref* | sort -nr | head -n 1 | awk '{print $2}')
    
    if [ -z "$DISK_REF_DIR" ]; then
        log "Erro: Disco não encontrado no XVA." "ERROR"
        exit 1
    fi
    
    log "Convertendo para RAW..."
    /usr/local/bin/xva-img -p disk-export "$DISK_REF_DIR/" "$WORK_DIR/disk.raw"
    
    if [ ! -f "$WORK_DIR/disk.raw" ]; then
        log "Erro na conversão RAW." "ERROR"
        exit 1
    fi
    
    # 4. Importação
    log "Importando disco para $TARGET_STORAGE..."
    if ! qm importdisk $VMID "$WORK_DIR/disk.raw" $TARGET_STORAGE --format raw; then
        log "CRITICAL: Falha no 'qm importdisk'. Verifique espaço no storage." "ERROR"
        exit 1
    fi
    
    # 5. Anexar e Boot
    log "Anexando disco..."
    IMPORTED_DISK=$(qm config $VMID | grep unused | head -n 1 | awk '{print $2}')
    if [ -n "$IMPORTED_DISK" ]; then
        qm set $VMID --scsi0 $IMPORTED_DISK,ssd=1
        qm set $VMID --boot c --bootdisk scsi0
        qm set $VMID --agent 1
    else
        log "Erro ao anexar disco." "ERROR"
    fi
    
    # 6. Limpeza
    log "Limpando temporários..."
    rm -rf "$WORK_DIR/Ref"*
    rm -f "$WORK_DIR/disk.raw"
    rm -f "$WORK_DIR/ova.xml"
    
    log "SUCESSO! VM $VMID Importada." "SUCCESS"
}

# --- EXECUÇÃO ---
clear
log "==============================================="
log "   XEN TO PROXMOX - IMPORT WIZARD v1.2"
log "==============================================="

check_dependencies
detect_usb
select_file
parse_audit_data
configure_vm
run_import