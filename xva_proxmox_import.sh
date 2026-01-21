#!/bin/bash
# ============================================================
# MIGRATOR PRO: XENSERVER TO PROXMOX (IMPORT & CONVERT)
# Versão: 1.1 (Fix xxhash dependency)
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
    # Remove códigos de cor para o arquivo de log
    echo "[$(date +'%H:%M:%S')] [$level] $msg" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"
    
    # Se o USB estiver montado, tenta salvar lá também (Dual Logging)
    if [ -n "$MOUNT_POINT" ] && mountpoint -q "$MOUNT_POINT"; then
        echo "[$(date +'%H:%M:%S')] [$level] $msg" | sed 's/\x1b\[[0-9;]*m//g' >> "$MOUNT_POINT/import_log.txt"
    fi
}

check_dependencies() {
    log "Verificando dependências..."
    
    if ! command -v xva-img &> /dev/null; then
        log "Ferramenta 'xva-img' não encontrada. Iniciando instalação automática..." "WARN"
        log "Atualizando repositórios e instalando compiladores (pode demorar)..."
        apt-get update -qq
        # CORREÇÃO V1.1: Adicionado libxxhash-dev
        apt-get install -y cmake g++ libssl-dev make git pv libxxhash-dev -qq
        
        log "Baixando e compilando xva-img..."
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
            log "Falha ao instalar xva-img. Verifique se o pacote libxxhash-dev foi instalado." "ERROR"
            exit 1
        fi
    else
        log "xva-img já está instalado." "SUCCESS"
    fi
    
    # Instala pv se não tiver (para barra de progresso)
    if ! command -v pv &> /dev/null; then apt-get install -y pv -qq; fi
}

# --- FUNÇÕES DE WIZARD ---

detect_usb() {
    log "Detectando unidades USB..."
    # Lista partições que não são do sistema (ignora sda, pve-root, etc) e são grandes
    mapfile -t DISKS < <(lsblk -rn -o NAME,SIZE,TRAN,MOUNTPOINT | grep "usb" | grep -v "sda")
    
    if [ ${#DISKS[@]} -eq 0 ]; then
        # Fallback: Tenta listar sd* que não estão montados na raiz
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
    
    # Se já estiver montado, usa o atual
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
    # Tenta limpar data do nome (ex: VMName_2026-01-01 -> VMName)
    CLEAN_NAME=$(echo "$VM_NAME_RAW" | sed -E 's/_[0-9]{4}-[0-9]{2}-[0-9]{2}.*$//')
}

parse_audit_data() {
    log "Procurando dados de auditoria para '$CLEAN_NAME'..."
    
    # Tenta encontrar o arquivo de auditoria correspondente
    AUDIT_FILE=$(find "$MOUNT_POINT" -name "*${CLEAN_NAME}*_INFO.txt" | head -n 1)
    
    # Valores padrão
    SUGGEST_CPU=2
    SUGGEST_RAM=2048
    SUGGEST_MACS=()
    SUGGEST_VLANS=()
    
    if [ -f "$AUDIT_FILE" ]; then
        log "Arquivo de auditoria encontrado: $(basename "$AUDIT_FILE")" "SUCCESS"
        
        # Extrai CPU
        CPU_READ=$(grep "VCPUs-max" "$AUDIT_FILE" | head -1 | awk '{print $NF}')
        if [ -n "$CPU_READ" ]; then SUGGEST_CPU=$CPU_READ; fi
        
        # Extrai RAM (Bytes -> MB)
        RAM_BYTES=$(grep "memory-static-max" "$AUDIT_FILE" | head -1 | awk '{print $NF}')
        if [ -n "$RAM_BYTES" ]; then 
            SUGGEST_RAM=$((RAM_BYTES / 1024 / 1024))
        fi
        
        # Extrai MACs e VLANs (Lógica complexa de parsing de blocos VIF)
        # Lê o arquivo linha a linha para correlacionar VIF com MAC e Rede
        while IFS= read -r line; do
            if [[ $line == *"[VIF:"* ]]; then
                current_vif="true"
                current_mac=""
                current_net=""
            fi
            
            if [[ $line == *"MAC ( RO):"* ]] && [ "$current_vif" == "true" ]; then
                current_mac=$(echo $line | awk '{print $4}')
            fi
            
            # Tenta pegar nome da rede/VLAN (ex: VLAN304_SPEEDTEST)
            if [[ $line == *"network-name-label"* ]] && [ "$current_vif" == "true" ]; then
                current_net=$(echo $line | awk '{print $4}')
                
                # Extrai número da VLAN do nome se existir (ex: VLAN304 -> 304)
                vlan_id=""
                if [[ $current_net =~ VLAN([0-9]+) ]]; then
                    vlan_id="${BASH_REMATCH[1]}"
                elif [[ $current_net =~ vlan([0-9]+) ]]; then
                    vlan_id="${BASH_REMATCH[1]}"
                fi
                
                if [ -n "$current_mac" ]; then
                    SUGGEST_MACS+=("$current_mac")
                    SUGGEST_VLANS+=("${vlan_id:-1}") # Se não achar vlan, usa 1 (default)
                    current_vif="false" # Reseta para o próximo
                fi
            fi
        done < "$AUDIT_FILE"
        
    else
        log "AVISO: Arquivo de auditoria não encontrado. Usando valores padrão." "WARN"
    fi
}

configure_vm() {
    echo ""
    log "--- CONFIGURAÇÃO DA NOVA VM ---"
    
    # 1. ID
    NEXT_ID=$(pvesh get /cluster/nextid)
    read -p "ID da Nova VM [$NEXT_ID]: " VMID
    VMID=${VMID:-$NEXT_ID}
    
    # 2. Nome
    read -p "Nome da VM [$CLEAN_NAME]: " VMNAME
    VMNAME=${VMNAME:-$CLEAN_NAME}
    
    # 3. CPU/RAM (Com sugestão da auditoria)
    echo "Configuração Detectada: ${SUGGEST_CPU} vCPUs / ${SUGGEST_RAM} MB RAM"
    read -p "Deseja manter esta configuração? [S/n]: " hw_conf
    hw_conf=${hw_conf:-S}
    
    if [[ "$hw_conf" =~ ^[nN]$ ]]; then
        read -p "Novos vCPUs: " SUGGEST_CPU
        read -p "Nova RAM (MB): " SUGGEST_RAM
    fi
    
    # 4. Storage Destino
    echo ""
    log "Storages Disponíveis no Proxmox:"
    pvesm status | grep active | awk '{print $1 " (" $2 ")"}'
    read -p "Digite o nome do Storage de Destino [local-lvm]: " TARGET_STORAGE
    TARGET_STORAGE=${TARGET_STORAGE:-local-lvm}
    
    # 5. Local de Conversão Temporária
    echo ""
    log "Local para Conversão Temporária (.raw):"
    log "[1] Local ($TEMP_DIR_LOCAL) - Mais rápido (Requer espaço livre no root)"
    log "[2] USB ($MOUNT_POINT) - Mais lento, poupa espaço local"
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
    
    # 1. Criar VM Esqueleto
    log "Criando VM $VMID ($VMNAME)..."
    qm create $VMID --name "$VMNAME" --memory $SUGGEST_RAM --cores $SUGGEST_CPU --ostype l26 --scsihw virtio-scsi-pci
    
    # 2. Configurar Rede (Clonagem de MACs e VLANs)
    log "Configurando Interfaces de Rede..."
    # Se não detectou MACs (sem auditoria), cria uma padrão
    if [ ${#SUGGEST_MACS[@]} -eq 0 ]; then
        log "Nenhuma interface detectada na auditoria. Criando net0 padrão." "WARN"
        qm set $VMID --net0 virtio,bridge=$DEFAULT_BRIDGE
    else
        idx=0
        for mac in "${SUGGEST_MACS[@]}"; do
            vlan="${SUGGEST_VLANS[$idx]}"
            tag_cmd=""
            if [ -n "$vlan" ] && [ "$vlan" != "1" ]; then
                tag_cmd=",tag=$vlan"
            fi
            
            log "  -> Adicionando net$idx: MAC=$mac Bridge=$DEFAULT_BRIDGE VLAN=$vlan"
            qm set $VMID --net$idx virtio,bridge=$DEFAULT_BRIDGE,macaddr=$mac$tag_cmd
            ((idx++))
        done
    fi
    
    # 3. Conversão XVA -> RAW
    log "Extraindo e Convertendo disco (Isso vai demorar)..."
    log "Origem: $XVA_FILE"
    log "Temp: $WORK_DIR/disk.raw"
    
    # Limpa temp anterior
    rm -rf "$WORK_DIR/Ref"* 2>/dev/null
    rm -f "$WORK_DIR/disk.raw" 2>/dev/null
    
    # Extrai o XVA (é um tar)
    tar -xf "$XVA_FILE" -C "$WORK_DIR"
    if [ $? -ne 0 ]; then log "Erro ao extrair XVA." "ERROR"; exit 1; fi
    
    # Encontra o diretório de referência do disco (Ref:X)
    # Pega o maior diretório dentro do pacote extraído (assumindo ser o disco principal)
    DISK_REF_DIR=$(du -s "$WORK_DIR"/Ref* | sort -nr | head -n 1 | awk '{print $2}')
    
    if [ -z "$DISK_REF_DIR" ]; then
        log "Erro: Não foi possível identificar o disco dentro do XVA." "ERROR"
        exit 1
    fi
    
    log "Convertendo blocos de $DISK_REF_DIR para RAW..."
    # Usa xva-img e pv para mostrar progresso
    /usr/local/bin/xva-img -p disk-export "$DISK_REF_DIR/" "$WORK_DIR/disk.raw"
    
    if [ ! -f "$WORK_DIR/disk.raw" ]; then
        log "Erro: Arquivo RAW não foi gerado." "ERROR"
        exit 1
    fi
    
    # 4. Importação para o Storage
    log "Importando disco RAW para o Storage $TARGET_STORAGE..."
    qm importdisk $VMID "$WORK_DIR/disk.raw" $TARGET_STORAGE --format raw
    if [ $? -ne 0 ]; then log "Erro na importação do disco." "ERROR"; exit 1; fi
    
    # 5. Anexar disco e Boot
    log "Anexando disco à VM..."
    # Descobre o nome do disco importado (ex: vm-100-disk-0)
    IMPORTED_DISK=$(qm config $VMID | grep unused | head -n 1 | awk '{print $2}')
    
    if [ -n "$IMPORTED_DISK" ]; then
        qm set $VMID --scsi0 $IMPORTED_DISK
        qm set $VMID --boot c --bootdisk scsi0
        # Habilita agente QEMU e SSD emulation
        qm set $VMID --agent 1
        qm set $VMID --scsi0 $IMPORTED_DISK,ssd=1
    else
        log "Erro: Não consegui anexar o disco automaticamente." "ERROR"
    fi
    
    # 6. Limpeza
    log "Limpando arquivos temporários..."
    rm -rf "$WORK_DIR/Ref"*
    rm -f "$WORK_DIR/disk.raw"
    # Remove header files do XVA
    rm -f "$WORK_DIR/ova.xml"
    
    log "------------------------------------------------"
    log "IMPORTAÇÃO CONCLUÍDA COM SUCESSO!" "SUCCESS"
    log "VM ID: $VMID"
    log "Nome: $VMNAME"
    log "Verifique as configurações de rede antes de iniciar."
}

# --- EXECUÇÃO ---
clear
log "==============================================="
log "   XEN TO PROXMOX - IMPORT WIZARD v1.1"
log "==============================================="

check_dependencies
detect_usb
select_file
parse_audit_data
configure_vm
run_import