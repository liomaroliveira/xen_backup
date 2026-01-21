#!/bin/bash
# ============================================================
# MIGRATOR PRO: XENSERVER TO PROXMOX (IMPORT & CONVERT)
# Versão: 1.4 (Bridge Menu & VLAN-Aware Auto-Fix)
# ============================================================

# --- CONFIGURAÇÕES ---
LOG_FILE="/var/log/xva_import_$(date +%Y%m%d_%H%M).log"
TEMP_DIR_LOCAL="/var/tmp/xva_conversion"

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
        apt-get install -y cmake g++ libssl-dev make git pv libxxhash-dev -qq
        
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
    # Garante numfmt para calculos legiveis
    if ! command -v numfmt &> /dev/null; then apt-get install -y coreutils -qq; fi
    log "Dependências OK." "SUCCESS"
}

# --- FUNÇÕES DE REDE (NOVO) ---

configure_bridge_vlan() {
    local bridge=$1
    
    # Verifica se já é VLAN Aware
    if grep -q "iface $bridge" /etc/network/interfaces && grep -q "bridge-vlan-aware yes" /etc/network/interfaces; then
        log "Bridge '$bridge' já está configurada como VLAN-Aware." "SUCCESS"
        return 0
    fi

    log "AVISO: A bridge '$bridge' NÃO está configurada como 'bridge-vlan-aware yes'." "WARN"
    log "Sem isso, as VLANs da VM podem não funcionar e gerar erro no boot."
    echo ""
    read -p "Deseja que eu ative o suporte a VLAN na bridge '$bridge' agora? (Isso recarregará a rede) [y/N]: " fix_vlan
    
    if [[ "$fix_vlan" =~ ^[yY]$ ]]; then
        log "Aplicando correção na rede..."
        
        # 1. Backup
        cp /etc/network/interfaces /etc/network/interfaces.bak.$(date +%s)
        log "Backup da rede salvo em /etc/network/interfaces.bak.*"
        
        # 2. Inserir configuração (Usa sed para adicionar a linha na indentação correta)
        # Procura a definição da interface e adiciona a linha logo abaixo
        sed -i "/iface $bridge inet/a \\ \\ \\ \\ bridge-vlan-aware yes" /etc/network/interfaces
        
        # 3. Recarregar rede
        log "Recarregando configurações de rede (ifreload -a)..."
        ifreload -a
        
        if [ $? -eq 0 ]; then
            log "Rede atualizada com sucesso! VLANs ativadas." "SUCCESS"
        else
            log "Falha ao recarregar a rede. Verifique '/etc/network/interfaces'." "ERROR"
            # Restaura backup em caso de erro crítico? Opcional, aqui mantemos para análise.
        fi
    else
        log "Mantendo configuração atual (Risco de erro 'status 6400')." "WARN"
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
        read -p "Digite o caminho completo (ex: /mnt/pve/backups): " custom_path
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
    if [ ${#DISKS[@]} -eq 0 ]; then
        mapfile -t DISKS < <(lsblk -rn -o NAME,SIZE,TRAN,MOUNTPOINT | grep "sd" | grep -v "sda")
    fi

    if [ ${#DISKS[@]} -eq 0 ]; then
        log "Nenhum disco USB encontrado." "ERROR"
        exit 1
    fi

    echo "------------------------------------------------"
    i=1
    for disk in "${DISKS[@]}"; do
        echo "[$i] /dev/$disk"
        ((i++))
    done
    echo "------------------------------------------------"
    read -p "Número do HD: " disk_opt
    
    SELECTED_DISK_LINE="${DISKS[$((disk_opt-1))]}"
    SELECTED_DEV="/dev/$(echo $SELECTED_DISK_LINE | awk '{print $1}')"
    
    MOUNT_POINT="/mnt/xva_import_usb"
    mkdir -p $MOUNT_POINT
    
    CURRENT_MOUNT=$(echo $SELECTED_DISK_LINE | awk '{print $4}')
    if [ -n "$CURRENT_MOUNT" ]; then
        MOUNT_POINT="$CURRENT_MOUNT"
    else
        mount $SELECTED_DEV $MOUNT_POINT
    fi
}

select_file() {
    log "Buscando arquivos .xva em $MOUNT_POINT..."
    mapfile -t FILES < <(find "$MOUNT_POINT" -maxdepth 3 -name "*.xva" | sort)

    if [ ${#FILES[@]} -eq 0 ]; then
        log "Nenhum arquivo .xva encontrado neste local." "ERROR"
        exit 1
    fi

    echo "----------------------------------------------------------------"
    printf "%-3s | %-50s | %-10s\n" "ID" "ARQUIVO" "TAMANHO"
    echo "----------------------------------------------------------------"
    i=1
    for f in "${FILES[@]}"; do
        fname=$(basename "$f")
        fsize=$(ls -lh "$f" | awk '{print $5}')
        printf "%-3s | %-50s | %-10s\n" "$i" "${fname:0:50}" "$fsize"
        ((i++))
    done
    echo "----------------------------------------------------------------"
    
    read -p "Arquivo ID: " file_opt
    XVA_FILE="${FILES[$((file_opt-1))]}"
    VM_NAME_RAW=$(basename "$XVA_FILE" .xva)
    CLEAN_NAME=$(echo "$VM_NAME_RAW" | sed -E 's/_[0-9]{4}-[0-9]{2}-[0-9]{2}.*$//' | tr '_' '-')
}

parse_audit_data() {
    SEARCH_NAME=$(echo "$CLEAN_NAME" | tr '-' '_') 
    AUDIT_FILE=$(find "$MOUNT_POINT" -name "*${SEARCH_NAME}*_INFO.txt" | head -n 1)
    
    SUGGEST_CPU=2
    SUGGEST_RAM=2048
    SUGGEST_MACS=()
    SUGGEST_VLANS=()
    
    if [ -f "$AUDIT_FILE" ]; then
        log "Auditoria encontrada: $(basename "$AUDIT_FILE")" "SUCCESS"
        CPU_READ=$(grep "VCPUs-max" "$AUDIT_FILE" | head -1 | awk '{print $NF}')
        [ -n "$CPU_READ" ] && SUGGEST_CPU=$CPU_READ
        RAM_BYTES=$(grep "memory-static-max" "$AUDIT_FILE" | head -1 | awk '{print $NF}')
        [ -n "$RAM_BYTES" ] && SUGGEST_RAM=$((RAM_BYTES / 1024 / 1024))
        
        while IFS= read -r line; do
            if [[ $line == *"[VIF:"* ]]; then vif_active="true"; mac=""; net=""; fi
            if [[ $line == *"MAC ( RO):"* ]] && [ "$vif_active" == "true" ]; then mac=$(echo $line | awk '{print $4}'); fi
            if [[ $line == *"network-name-label"* ]] && [ "$vif_active" == "true" ]; then
                net=$(echo $line | awk '{print $4}')
                vlan=""
                if [[ $net =~ VLAN([0-9]+) ]]; then vlan="${BASH_REMATCH[1]}"
                elif [[ $net =~ vlan([0-9]+) ]]; then vlan="${BASH_REMATCH[1]}"; fi
                
                if [ -n "$mac" ]; then
                    SUGGEST_MACS+=("$mac")
                    SUGGEST_VLANS+=("${vlan:-1}")
                    vif_active="false"
                fi
            fi
        done < "$AUDIT_FILE"
    else
        log "Auditoria não encontrada. Usando valores padrão." "WARN"
    fi
}

validate_resources() {
    log "Validando recursos..."
    HOST_FREE_RAM=$(free -m | awk '/^Mem:/{print $7}')
    if [ "$SUGGEST_RAM" -gt "$HOST_FREE_RAM" ]; then
        log "ALERTA: Memória insuficiente! VM pede ${SUGGEST_RAM}MB, Host tem ${HOST_FREE_RAM}MB livres." "WARN"
        read -p "Continuar? [y/N]: " force_ram
        if [[ ! "$force_ram" =~ ^[yY]$ ]]; then exit 1; fi
    fi
}

configure_vm() {
    echo ""
    log "--- CONFIGURAÇÃO ---"
    
    NEXT_ID=$(pvesh get /cluster/nextid)
    read -p "ID VM [$NEXT_ID]: " VMID
    VMID=${VMID:-$NEXT_ID}
    
    read -p "Nome [$CLEAN_NAME]: " VMNAME
    VMNAME=${VMNAME:-$CLEAN_NAME}
    VMNAME=$(echo "$VMNAME" | tr '_' '-')
    
    echo "Recursos: ${SUGGEST_CPU} vCPUs | ${SUGGEST_RAM} MB RAM"
    validate_resources
    
    # --- MENU DE STORAGE (LEGÍVEL) ---
    echo ""
    log "Selecione o Storage de Destino:"
    mapfile -t STORAGES < <(pvesm status -enabled | awk 'NR>1 {print $1}')
    
    if [ ${#STORAGES[@]} -eq 0 ]; then log "Sem storage!" "ERROR"; exit 1; fi

    i=1
    for store in "${STORAGES[@]}"; do
        # Proxmox reporta em KB (units=1024), converte para legível (IEC)
        size_kb=$(pvesm status -storage "$store" | awk 'NR==2 {print $6}')
        # Se pvesm retornar bytes em algumas versoes, ajustamos. Padrao KB.
        # numfmt --from-unit=1024 converte de KB para humano
        size_human=$(numfmt --from-unit=1024 --to=iec $size_kb 2>/dev/null || echo "${size_kb}KB")
        type=$(pvesm status -storage "$store" | awk 'NR==2 {print $2}')
        echo "  [$i] $store (Tipo: $type | Livre: $size_human)"
        ((i++))
    done
    
    read -p "Opção: " store_opt
    TARGET_STORAGE="${STORAGES[$((store_opt-1))]}"
    [ -z "$TARGET_STORAGE" ] && TARGET_STORAGE="local-lvm"
    log "Storage: $TARGET_STORAGE" "INFO"

    # Conversão
    echo ""
    log "Local Temporário de Conversão:"
    log "  [1] Local ($TEMP_DIR_LOCAL) - Rápido"
    log "  [2] Na Origem ($MOUNT_POINT) - Economiza espaço local"
    read -p "Opção [1]: " temp_opt
    
    if [ "$temp_opt" == "2" ]; then
        WORK_DIR="$MOUNT_POINT/temp_conversion"
    else
        WORK_DIR="$TEMP_DIR_LOCAL"
    fi
    mkdir -p "$WORK_DIR"
    
    # --- MENU DE REDE (NUMÉRICO + AUTO FIX) ---
    echo ""
    log "Selecione a Bridge de Rede:"
    mapfile -t BRIDGES < <(ip -br link show type bridge | awk '{print $1}')
    
    if [ ${#BRIDGES[@]} -eq 0 ]; then
        log "Nenhuma bridge encontrada! Criando VM sem rede." "WARN"
        SEL_BRIDGE=""
    else
        i=1
        for br in "${BRIDGES[@]}"; do
            echo "  [$i] $br"
            ((i++))
        done
        read -p "Opção de Bridge: " br_opt
        SEL_BRIDGE="${BRIDGES[$((br_opt-1))]}"
        [ -z "$SEL_BRIDGE" ] && SEL_BRIDGE="vmbr0"
        log "Bridge Selecionada: $SEL_BRIDGE" "INFO"
    fi
    
    USE_VLAN="n"
    if [ ${#SUGGEST_VLANS[@]} -gt 0 ] && [ -n "$SEL_BRIDGE" ]; then
        log "VLANs detectadas: ${SUGGEST_VLANS[*]}"
        read -p "Deseja aplicar as Tags de VLAN na VM? [y/N]: " vlan_opt
        USE_VLAN=${vlan_opt:-n}
        
        # AUTO-FIX VLAN AWARE
        if [[ "$USE_VLAN" =~ ^[yY]$ ]]; then
            configure_bridge_vlan "$SEL_BRIDGE"
        fi
    fi
}

run_import() {
    log "Iniciando criação..."
    
    # 1. Criar VM
    if ! qm create $VMID --name "$VMNAME" --memory $SUGGEST_RAM --cores $SUGGEST_CPU --ostype l26 --scsihw virtio-scsi-pci; then
        log "Falha ao criar VM. Verifique ID/Nome." "ERROR"
        exit 1
    fi
    
    # 2. Configurar Rede
    log "Configurando Rede..."
    if [ ${#SUGGEST_MACS[@]} -eq 0 ] || [ -z "$SEL_BRIDGE" ]; then
        [ -n "$SEL_BRIDGE" ] && qm set $VMID --net0 virtio,bridge=$SEL_BRIDGE
    else
        idx=0
        for mac in "${SUGGEST_MACS[@]}"; do
            vlan="${SUGGEST_VLANS[$idx]}"
            tag_cmd=""
            if [[ "$USE_VLAN" =~ ^[yY]$ ]] && [ -n "$vlan" ] && [ "$vlan" != "1" ]; then
                tag_cmd=",tag=$vlan"
            fi
            
            log "  -> net$idx: MAC=$mac Bridge=$SEL_BRIDGE $tag_cmd"
            qm set $VMID --net$idx virtio,bridge=$SEL_BRIDGE,macaddr=$mac$tag_cmd
            ((idx++))
        done
    fi
    
    # 3. Conversão e Importação
    log "Extraindo XVA..."
    rm -rf "$WORK_DIR/Ref"* 2>/dev/null
    rm -f "$WORK_DIR/disk.raw" 2>/dev/null
    
    tar -xf "$XVA_FILE" -C "$WORK_DIR"
    DISK_REF_DIR=$(du -s "$WORK_DIR"/Ref* | sort -nr | head -n 1 | awk '{print $2}')
    
    if [ -z "$DISK_REF_DIR" ]; then log "Disco não encontrado no XVA." "ERROR"; exit 1; fi
    
    log "Convertendo para RAW..."
    /usr/local/bin/xva-img -p disk-export "$DISK_REF_DIR/" "$WORK_DIR/disk.raw"
    
    if [ ! -f "$WORK_DIR/disk.raw" ]; then log "Erro na conversão." "ERROR"; exit 1; fi
    
    log "Importando para $TARGET_STORAGE..."
    if ! qm importdisk $VMID "$WORK_DIR/disk.raw" $TARGET_STORAGE --format raw; then
        log "Erro na importação. Verifique espaço no storage." "ERROR"
        exit 1
    fi
    
    # 4. Finalização
    IMPORTED_DISK=$(qm config $VMID | grep unused | head -n 1 | awk '{print $2}')
    if [ -n "$IMPORTED_DISK" ]; then
        qm set $VMID --scsi0 $IMPORTED_DISK,ssd=1
        qm set $VMID --boot c --bootdisk scsi0
        qm set $VMID --agent 1
    else
        log "AVISO: Disco importado, mas não anexado. Verifique Hardware." "WARN"
    fi
    
    # Limpeza
    rm -rf "$WORK_DIR/Ref"* "$WORK_DIR/disk.raw" "$WORK_DIR/ova.xml"
    
    log "SUCESSO! VM $VMID criada." "SUCCESS"
}

# --- EXECUÇÃO ---
clear
log "==============================================="
log "   XEN TO PROXMOX - IMPORT WIZARD v1.4"
log "==============================================="

check_dependencies
select_source
select_file
parse_audit_data
configure_vm
run_import