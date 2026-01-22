#!/bin/bash
# ============================================================
# MIGRATOR PRO: XENSERVER TO PROXMOX (IMPORT & CONVERT)
# Versão: 2.1 (Safe Cancel & Atomic Logging)
# ============================================================

# --- CONFIGURAÇÕES ---
LOG_FILE="/var/log/xva_import_$(date +%Y%m%d_%H%M).log"
TEMP_DIR_ROOT="/var/tmp/xva_conversion"

# --- VARIÁVEIS GLOBAIS DE CONTROLE ---
declare -a BATCH_FILES
declare -a BATCH_CONFIGS
# Variáveis para rastrear o estado atual em caso de cancelamento
CURRENT_VMID=""
CURRENT_WORK_DIR=""
CURRENT_STEP=""

# --- CORES ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- FUNÇÕES DE SISTEMA ---

# Log Atômico: Grava e força sync no disco imediatamente
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
    
    # Exibe na tela
    echo -e "${color}[$(date +'%H:%M:%S')] [$level] $msg${NC}"
    
    # Grava no arquivo local e força escrita física
    echo "[$(date +'%H:%M:%S')] [$level] $msg" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"
    sync "$LOG_FILE"
    
    # Grava no USB (se montado) e força escrita física
    if [ -n "$MOUNT_POINT" ] && mountpoint -q "$MOUNT_POINT"; then
        echo "[$(date +'%H:%M:%S')] [$level] $msg" | sed 's/\x1b\[[0-9;]*m//g' >> "$MOUNT_POINT/import_log.txt"
        sync "$MOUNT_POINT/import_log.txt"
    fi
}

# Trap para Ctrl+C (SIGINT)
cleanup_on_cancel() {
    echo ""
    log "===================================================" "ERROR"
    log "!!! INTERRUPÇÃO DETECTADA (CTRL+C) !!!" "ERROR"
    log "Iniciando protocolo de limpeza de emergência..." "WARN"
    
    # 1. Matar processos filhos (tar, xva-img, qm import)
    log "   -> Parando processos ativos..."
    pkill -P $$ 2>/dev/null
    
    # 2. Remover VM incompleta (apenas se estava sendo criada)
    if [ -n "$CURRENT_VMID" ]; then
        if qm status "$CURRENT_VMID" &>/dev/null; then
            log "   -> Removendo VM incompleta (ID $CURRENT_VMID)..."
            qm destroy "$CURRENT_VMID" --purge 2>/dev/null
            log "      VM $CURRENT_VMID destruída." "SUCCESS"
        fi
    fi
    
    # 3. Limpar arquivos temporários da extração atual
    if [ -n "$CURRENT_WORK_DIR" ] && [ -d "$CURRENT_WORK_DIR" ]; then
        log "   -> Removendo arquivos temporários parciais em: $CURRENT_WORK_DIR"
        rm -rf "$CURRENT_WORK_DIR"
        log "      Arquivos limpos." "SUCCESS"
    fi
    
    log "Limpeza concluída. O estado anterior foi restaurado." "SUCCESS"
    log "Processo abortado pelo usuário." "ERROR"
    exit 1
}

# Ativa o Trap
trap cleanup_on_cancel INT TERM

check_dependencies() {
    log "Verificando dependências..."
    if ! command -v xva-img &> /dev/null; then
        log "Instalando xva-img..." "WARN"
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
    for cmd in pv numfmt; do
        if ! command -v $cmd &> /dev/null; then apt-get install -y coreutils pv -qq; fi
    done
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

# --- SELEÇÃO DE ARQUIVOS (BATCH) ---

select_files_batch() {
    log "Buscando arquivos .xva..."
    mapfile -t FILES < <(find "$MOUNT_POINT" -maxdepth 3 -name "*.xva" | sort)
    [ ${#FILES[@]} -eq 0 ] && { log "Nenhum arquivo .xva encontrado." "ERROR"; exit 1; }

    echo "----------------------------------------------------------------"
    printf "%-3s | %-50s | %-10s\n" "ID" "ARQUIVO" "TAMANHO (XVA)"
    echo "----------------------------------------------------------------"
    i=1
    for f in "${FILES[@]}"; do
        fsize=$(ls -lh "$f" | awk '{print $5}')
        printf "%-3s | %-50s | %-10s\n" "$i" "${f##*/}" "$fsize"
        ((i++))
    done
    echo "----------------------------------------------------------------"
    echo "Digite os números dos arquivos para importar, separados por espaço."
    echo "Exemplo: 3 1 5 (Importará o 3, depois o 1, depois o 5)"
    read -p "Seleção: " selection_input
    
    MAX_XVA_SIZE=0
    
    for id in $selection_input; do
        if [[ "$id" =~ ^[0-9]+$ ]] && [ "$id" -le "${#FILES[@]}" ] && [ "$id" -gt 0 ]; then
            FILE_PATH="${FILES[$((id-1))]}"
            BATCH_FILES+=("$FILE_PATH")
            SIZE_BYTES=$(stat -c%s "$FILE_PATH")
            if [ "$SIZE_BYTES" -gt "$MAX_XVA_SIZE" ]; then MAX_XVA_SIZE=$SIZE_BYTES; fi
        else
            log "AVISO: ID $id inválido, ignorado." "WARN"
        fi
    done
    
    if [ ${#BATCH_FILES[@]} -eq 0 ]; then log "Nenhum arquivo selecionado." "ERROR"; exit 1; fi
    log "Total de VMs selecionadas: ${#BATCH_FILES[@]}" "INFO"
    
    # Estimativa Rápida (XVA * 2.2)
    ESTIMATED_MAX_RAW=$(echo "$MAX_XVA_SIZE * 2.2" | bc | cut -d. -f1)
    ESTIMATED_MAX_HUMAN=$(numfmt --to=iec --suffix=B $ESTIMATED_MAX_RAW)
}

# --- SELEÇÃO DE ESPAÇO TEMPORÁRIO ---

select_temp_storage_global() {
    echo ""
    log "SELECIONE ONDE PROCESSAR OS ARQUIVOS TEMPORÁRIOS (.raw)"
    log "Requisito (Maior VM): ~$ESTIMATED_MAX_HUMAN livres."
    echo "---------------------------------------------------------"
    
    # Opção 1: USB
    usb_free=$(df --output=avail -B1 "$MOUNT_POINT" | tail -1)
    usb_human=$(numfmt --to=iec --suffix=B $usb_free)
    echo "  [1] HD USB Externo (Livre: $usb_human)"
    
    # Opção 2: Root
    root_free=$(df --output=avail -B1 "$TEMP_DIR_ROOT" | tail -1)
    root_human=$(numfmt --to=iec --suffix=B $root_free)
    echo "  [2] Partição Root/Local (Livre: $root_human)"
    
    # Opções 3+: Storages do Proxmox
    mapfile -t FILE_STORAGES < <(pvesm status -content images,iso,backup,rootdir -enabled | awk 'NR>1 {print $1}')
    declare -a STORAGE_PATHS
    idx=3
    
    for fs_store in "${FILE_STORAGES[@]}"; do
        path=$(pvesm path "$fs_store" "tmp_check" 2>/dev/null | xargs dirname 2>/dev/null)
        if [ -z "$path" ]; then
             path=$(grep -A5 "^dir: $fs_store" /etc/pve/storage.cfg | grep "path" | awk '{print $2}')
        fi
        
        if [ -n "$path" ] && [ -d "$path" ]; then
            store_free=$(df --output=avail -B1 "$path" | tail -1)
            store_human=$(numfmt --to=iec --suffix=B $store_free)
            echo "  [$idx] Storage Proxmox: $fs_store (Livre: $store_human)"
            STORAGE_PATHS[$idx]="$path"
            ((idx++))
        fi
    done
    echo "---------------------------------------------------------"
    
    read -p "Opção: " temp_opt
    temp_opt=${temp_opt:-1}
    
    SELECTED_FREE=0
    
    if [ "$temp_opt" == "1" ]; then
        WORK_DIR_BASE="$MOUNT_POINT/temp_conversion"
        SELECTED_FREE=$usb_free
    elif [ "$temp_opt" == "2" ]; then
        WORK_DIR_BASE="$TEMP_DIR_ROOT"
        SELECTED_FREE=$root_free
    elif [ -n "${STORAGE_PATHS[$temp_opt]}" ]; then
        WORK_DIR_BASE="${STORAGE_PATHS[$temp_opt]}/temp_xva_import"
        SELECTED_FREE=$(df --output=avail -B1 "${STORAGE_PATHS[$temp_opt]}" | tail -1)
    else
        log "Opção inválida. Usando USB." "WARN"
        WORK_DIR_BASE="$MOUNT_POINT/temp_conversion"
        SELECTED_FREE=$usb_free
    fi
    
    if [ "$ESTIMATED_MAX_RAW" -gt "$SELECTED_FREE" ]; then
        log "ALERTA CRÍTICO: Espaço insuficiente no destino escolhido." "ERROR"
        log "Necessário: $ESTIMATED_MAX_HUMAN | Livre: $(numfmt --to=iec --suffix=B $SELECTED_FREE)"
        read -p "Continuar mesmo assim (risco de falha)? [y/N]: " force_space
        if [[ ! "$force_space" =~ ^[yY]$ ]]; then exit 1; fi
    fi
    
    mkdir -p "$WORK_DIR_BASE"
    log "Diretório temporário definido: $WORK_DIR_BASE" "SUCCESS"
}

# --- CONFIGURAÇÃO DAS VMS ---

configure_batch() {
    clear
    log "==============================================="
    log "   ETAPA DE CONFIGURAÇÃO (Batch Mode)"
    log "==============================================="
    
    counter=0
    for XVA_FILE in "${BATCH_FILES[@]}"; do
        VM_NAME_RAW=$(basename "$XVA_FILE" .xva)
        CLEAN_NAME=$(echo "$VM_NAME_RAW" | sed -E 's/_[0-9]{4}-[0-9]{2}-[0-9]{2}.*$//' | tr '_' '-')
        SEARCH_NAME=$(echo "$CLEAN_NAME" | tr '-' '_') 
        
        echo ""
        log ">> Configurando VM $((counter+1))/${#BATCH_FILES[@]}: $CLEAN_NAME"
        
        AUDIT_FILE=$(find "$MOUNT_POINT" -name "*${SEARCH_NAME}*_INFO.txt" | head -n 1)
        SUGGEST_CPU=2; SUGGEST_RAM=2048; SUGGEST_MACS=(); SUGGEST_VLANS=()
        if [ -f "$AUDIT_FILE" ]; then
            log "   Auditoria encontrada." "INFO"
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
        
        NEXT_ID=$(pvesh get /cluster/nextid)
        read -p "   ID VM [$NEXT_ID]: " VMID; VMID=${VMID:-$NEXT_ID}
        read -p "   Nome [$CLEAN_NAME]: " VMNAME; VMNAME=${VMNAME:-$CLEAN_NAME}; VMNAME=$(echo "$VMNAME" | tr '_' '-')
        
        echo "   Hardware: ${SUGGEST_CPU} vCPUs | ${SUGGEST_RAM} MB RAM"
        read -p "   Alterar hardware? [y/N]: " hw_opt
        if [[ "$hw_opt" =~ ^[yY]$ ]]; then
            read -p "   vCPUs: " SUGGEST_CPU
            read -p "   RAM (MB): " SUGGEST_RAM
        fi
        
        mapfile -t STORAGES < <(pvesm status -enabled | awk 'NR>1 {print $1}')
        echo "   Storages de Destino:"
        si=1
        for store in "${STORAGES[@]}"; do
             size_kb=$(pvesm status -storage "$store" | awk 'NR==2 {print $6}')
             size_human=$(numfmt --from-unit=1024 --to=iec $size_kb 2>/dev/null || echo "${size_kb}KB")
             echo "     [$si] $store (Livre: $size_human)"
             ((si++))
        done
        read -p "   Opção Storage: " store_opt; TARGET_STORAGE="${STORAGES[$((store_opt-1))]}"
        [ -z "$TARGET_STORAGE" ] && TARGET_STORAGE="local-lvm"
        
        mapfile -t BRIDGES < <(ip -br link show type bridge | awk '{print $1}')
        echo "   Bridges:"
        bi=1; for br in "${BRIDGES[@]}"; do echo "     [$bi] $br"; ((bi++)); done
        read -p "   Opção Bridge: " br_opt; SEL_BRIDGE="${BRIDGES[$((br_opt-1))]}"
        [ -z "$SEL_BRIDGE" ] && SEL_BRIDGE="vmbr0"
        
        USE_VLAN="n"
        if [ ${#SUGGEST_VLANS[@]} -gt 0 ]; then
             read -p "   Aplicar VLANs (${SUGGEST_VLANS[*]})? [y/N]: " vlan_opt; USE_VLAN=${vlan_opt:-n}
             [[ "$USE_VLAN" =~ ^[yY]$ ]] && configure_bridge_vlan "$SEL_BRIDGE"
        fi
        
        MACS_STR=$(IFS=,; echo "${SUGGEST_MACS[*]}")
        VLANS_STR=$(IFS=,; echo "${SUGGEST_VLANS[*]}")
        
        BATCH_CONFIGS[$counter]="$XVA_FILE|$VMID|$VMNAME|$SUGGEST_CPU|$SUGGEST_RAM|$TARGET_STORAGE|$SEL_BRIDGE|$USE_VLAN|$MACS_STR|$VLANS_STR"
        
        ((counter++))
        log "   Configuração salva." "SUCCESS"
    done
}

# --- EXECUÇÃO DO BATCH ---

run_batch() {
    clear
    log "==============================================="
    log "   INICIANDO IMPORTAÇÃO EM MASSA (${#BATCH_CONFIGS[@]} VMs)"
    log "==============================================="
    
    idx=0
    for CONFIG in "${BATCH_CONFIGS[@]}"; do
        IFS='|' read -r XVA_FILE VMID VMNAME CPU RAM TARGET BRIDGE USE_VLAN MACS_STR VLANS_STR <<< "$CONFIG"
        
        # Define variáveis globais para o Trap
        CURRENT_VMID="$VMID"
        CURRENT_WORK_DIR="$WORK_DIR_BASE/current_vm_${VMID}"
        CURRENT_STEP="Iniciando"
        
        echo ""
        log ">>> PROCESSANDO VM $((idx+1))/${#BATCH_CONFIGS[@]}: $VMNAME (ID $VMID)"
        log "    Arquivo: $(basename "$XVA_FILE")"
        log "    Alvo: $TARGET"
        
        # 1. Cria VM
        CURRENT_STEP="Criando VM"
        if ! qm create $VMID --name "$VMNAME" --memory $RAM --cores $CPU --ostype l26 --scsihw virtio-scsi-pci; then
            log "ERRO: Falha ao criar VM $VMID. Pulando..." "ERROR"
            ((idx++)); CURRENT_VMID=""; continue
        fi
        
        # 2. Rede
        IFS=',' read -r -a MACS <<< "$MACS_STR"
        IFS=',' read -r -a VLANS <<< "$VLANS_STR"
        
        if [ ${#MACS[@]} -eq 0 ]; then
             qm set $VMID --net0 virtio,bridge=$BRIDGE
        else
            net_i=0
            for mac in "${MACS[@]}"; do
                vlan="${VLANS[$net_i]}"
                tag_cmd=""
                [[ "$USE_VLAN" =~ ^[yY]$ ]] && [ -n "$vlan" ] && [ "$vlan" != "1" ] && tag_cmd=",tag=$vlan"
                qm set $VMID --net$net_i virtio,bridge=$BRIDGE,macaddr=$mac$tag_cmd
                ((net_i++))
            done
        fi
        
        # 3. Conversão
        CURRENT_STEP="Convertendo RAW"
        rm -rf "$CURRENT_WORK_DIR" 2>/dev/null
        mkdir -p "$CURRENT_WORK_DIR"
        
        log "    Extraindo XVA..."
        tar -xf "$XVA_FILE" -C "$CURRENT_WORK_DIR"
        
        DISK_REF_DIR=$(du -s "$CURRENT_WORK_DIR"/Ref* | sort -nr | head -n 1 | awk '{print $2}')
        if [ -z "$DISK_REF_DIR" ]; then log "ERRO: Disco não encontrado no XVA." "ERROR"; ((idx++)); CURRENT_VMID=""; continue; fi
        
        log "    Convertendo para RAW..."
        /usr/local/bin/xva-img -p disk-export "$DISK_REF_DIR/" "$CURRENT_WORK_DIR/disk.raw"
        
        if [ ! -f "$CURRENT_WORK_DIR/disk.raw" ]; then log "ERRO: Conversão falhou." "ERROR"; ((idx++)); CURRENT_VMID=""; continue; fi
        
        # 4. Importação
        CURRENT_STEP="Importando Disco"
        log "    Importando para $TARGET..."
        if ! qm importdisk $VMID "$CURRENT_WORK_DIR/disk.raw" $TARGET --format raw; then
            log "ERRO: Falha no qm importdisk." "ERROR"; ((idx++)); CURRENT_VMID=""; continue; fi
        
        # 5. Anexar
        IMPORTED_DISK=$(qm config $VMID | grep unused | head -n 1 | awk '{print $2}')
        if [ -n "$IMPORTED_DISK" ]; then
            qm set $VMID --scsi0 $IMPORTED_DISK,ssd=1
            qm set $VMID --boot c --bootdisk scsi0
            qm set $VMID --agent 1
        fi
        
        # 6. Limpeza
        CURRENT_STEP="Limpando"
        log "    Limpando temporários..."
        rm -rf "$CURRENT_WORK_DIR"
        
        log "    [SUCESSO] VM $VMID concluída." "SUCCESS"
        
        # Reseta variáveis de controle para evitar deleção acidental
        CURRENT_VMID=""
        CURRENT_WORK_DIR=""
        ((idx++))
    done
    
    log "==============================================="
    log "   LOTE FINALIZADO!" "SUCCESS"
    log "==============================================="
}

# --- EXECUÇÃO ---
clear
log "==============================================="
log "   XEN TO PROXMOX - IMPORT WIZARD v2.1"
log "==============================================="

check_dependencies
select_source
select_files_batch
select_temp_storage_global
configure_batch
run_batch