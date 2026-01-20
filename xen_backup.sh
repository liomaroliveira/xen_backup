#!/bin/bash
# ==========================================
# WIZARD DE BACKUP XENSERVER - V9.0 (SMART)
# ==========================================

# Configurações Iniciais
MOUNT_POINT="/mnt/usb_backup_wizard"
DATE_NOW=$(date +%Y-%m-%d_%H-%M)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILENAME="backup_log_${DATE_NOW}.txt"
TEMP_LOG="/tmp/${LOG_FILENAME}"

# Limite de segurança para Snapshot (em GB)
# Se houver menos que isso livre no SR, o script recomendará desligar a VM
SNAPSHOT_SAFE_MARGIN=2

# Função de Log
log_msg() {
    local msg="$1"
    echo "$msg"
    echo "[$(date '+%H:%M:%S')] $msg" >> "$TEMP_LOG"
}

# Função de Monitoramento
monitor_export() {
    local pid=$1
    local file=$2
    local delay=3
    
    echo "    (Monitorando progresso...)"
    while kill -0 $pid 2>/dev/null; do
        if [ -f "$file" ]; then
            current_size=$(ls -lh "$file" | awk '{print $5}')
            if [ -n "$current_size" ]; then
                printf "    >> Tamanho Atual do Arquivo: %-10s\r" "$current_size"
            fi
        fi
        sleep $delay
    done
    echo ""
}

clear
log_msg "=========================================="
log_msg "   WIZARD DE BACKUP XENSERVER - V9.0      "
log_msg "=========================================="
log_msg "Data: $DATE_NOW"

# ----------------------------------------
# 1. DETECÇÃO E MONTAGEM DO USB
# ----------------------------------------
echo ""
log_msg "[1/4] Detectando armazenamento..."

> /tmp/disk_list
lsblk -d -n -o NAME,SIZE,MODEL,TRAN | grep -v "sda" | grep "sd" | while read -r line; do
    echo "$line" >> /tmp/disk_list
done

if [ ! -s /tmp/disk_list ]; then
    log_msg "ERRO: Nenhum disco USB detectado."
    exit 1
fi

mapfile -t DISKS < /tmp/disk_list
i=1
for disk in "${DISKS[@]}"; do
    echo "  [$i] $disk"
    ((i++))
done

echo ""
read -p "Escolha o NÚMERO do HD Externo: " disk_opt
selected_disk_info="${DISKS[$((disk_opt-1))]}"
USB_DEVICE_NAME=$(echo "$selected_disk_info" | awk '{print $1}')
USB_DEVICE="/dev/$USB_DEVICE_NAME"

if [ -z "$USB_DEVICE_NAME" ]; then
    log_msg "Opção inválida."
    exit 1
fi

log_msg ">> Selecionado: $USB_DEVICE"
echo ""

# ----------------------------------------
# 2. MONTAGEM
# ----------------------------------------
log_msg "[2/4] Configuração de Montagem"
if mountpoint -q $MOUNT_POINT; then
    umount $MOUNT_POINT
fi

read -p "Deseja FORMATAR este disco para EXT4 AGORA? (Digite 'n' se já formatou) [s/N]: " format_opt
format_opt=${format_opt:-n}

mkdir -p $MOUNT_POINT

if [[ "$format_opt" =~ ^[sS]$ ]]; then
    log_msg "!!! ATENÇÃO: DADOS EM $USB_DEVICE SERÃO APAGADOS !!!"
    read -p "Digite 'SIM' para confirmar: " confirm
    if [ "$confirm" == "SIM" ]; then
        log_msg "Formatando..."
        mkfs.ext4 -F "$USB_DEVICE" >> "$TEMP_LOG" 2>&1
        mount "$USB_DEVICE" $MOUNT_POINT
    else
        log_msg "Cancelado."
        exit 0
    fi
else
    if [ -b "${USB_DEVICE}1" ]; then
        mount "${USB_DEVICE}1" $MOUNT_POINT 2>/dev/null || mount "$USB_DEVICE" $MOUNT_POINT
    else
        mount "$USB_DEVICE" $MOUNT_POINT
    fi
fi

if ! mountpoint -q $MOUNT_POINT; then
    log_msg "ERRO CRÍTICO: Falha ao montar o disco."
    exit 1
fi

FREE_SPACE=$(df -h $MOUNT_POINT | awk 'NR==2 {print $4}')
log_msg ">> Disco montado (Livre: $FREE_SPACE)"

echo ""
read -p "Deseja DESMONTAR automaticamente ao final? [S/n]: " auto_unmount_opt
AUTO_UNMOUNT=${auto_unmount_opt:-S}
log_msg ">> Opção de desmontagem automática: $AUTO_UNMOUNT"

# ----------------------------------------
# 3. ANÁLISE DE VMS E STORAGES
# ----------------------------------------
echo ""
log_msg "[3/4] Analisando VMs e Viabilidade de Backup..."
log_msg "Verificando espaço livre nos Storages para permitir snapshots..."
echo "--------------------------------------------------------------------------------------------------------------------"
printf "%-3s | %-18s | %-8s | %-12s | %-25s | %-15s\n" "ID" "NOME" "STATUS" "TAM. VM" "STORAGE (LIVRE)" "VIABILIDADE"
echo "--------------------------------------------------------------------------------------------------------------------"

declare -a UUIDS
declare -a NAMES
declare -a STATES
declare -a VIABILITY

VM_UUID_LIST=$(xe vm-list is-control-domain=false is-a-snapshot=false params=uuid --minimal | tr ',' ' ')

id=1
for uuid in $VM_UUID_LIST; do
    NAME=$(xe vm-param-get uuid=$uuid param-name=name-label)
    STATE=$(xe vm-param-get uuid=$uuid param-name=power-state)
    
    # Tamanho Total da VM
    DISK_SIZE_BYTES=0
    # Tenta descobrir o SR do primeiro disco (onde geralmente ocorre o snapshot crítico)
    SR_NAME="N/A"
    SR_FREE_GB=0
    
    # Lista VDIs
    VBD_LIST=$(xe vbd-list vm-uuid=$uuid type=Disk params=vdi-uuid --minimal | tr ',' ' ')
    FIRST_VDI_CHECKED=false
    
    for vdi in $VBD_LIST; do
        if [ -n "$vdi" ]; then
            SIZE=$(xe vdi-param-get uuid=$vdi param-name=virtual-size 2>/dev/null)
            DISK_SIZE_BYTES=$((DISK_SIZE_BYTES + SIZE))
            
            # Pega info do SR apenas do primeiro disco para exibir na tabela
            if [ "$FIRST_VDI_CHECKED" = false ]; then
                SR_UUID=$(xe vdi-param-get uuid=$vdi param-name=sr-uuid 2>/dev/null)
                if [ -n "$SR_UUID" ]; then
                    SR_NAME_RAW=$(xe sr-param-get uuid=$SR_UUID param-name=name-label 2>/dev/null)
                    SR_NAME="${SR_NAME_RAW:0:15}" # Corta nome longo
                    
                    # Calcula espaço livre deste SR
                    P_SIZE=$(xe sr-param-get uuid=$SR_UUID param-name=physical-size 2>/dev/null)
                    P_UTIL=$(xe sr-param-get uuid=$SR_UUID param-name=physical-utilisation 2>/dev/null)
                    if [ -n "$P_SIZE" ] && [ -n "$P_UTIL" ]; then
                         FREE_BYTES=$((P_SIZE - P_UTIL))
                         SR_FREE_GB=$((FREE_BYTES / 1024 / 1024 / 1024))
                    fi
                fi
                FIRST_VDI_CHECKED=true
            fi
        fi
    done
    DISK_GB=$((DISK_SIZE_BYTES / 1024 / 1024 / 1024))

    # Lógica de Viabilidade
    MSG_VIAVEL="ERRO"
    IS_VIABLE=true
    
    if [ "$STATE" == "halted" ]; then
        MSG_VIAVEL="OK (DIRETO)"
    else
        # Se estiver ligada, precisa de espaço para snapshot
        if [ "$SR_FREE_GB" -lt "$SNAPSHOT_SAFE_MARGIN" ]; then
            MSG_VIAVEL="REQ. DESLIGAR"
            IS_VIABLE=false # Marca como arriscado
        else
            MSG_VIAVEL="OK (SNAPSHOT)"
        fi
    fi

    printf "%-3s | %-18s | %-8s | ~%-4s GB    | %-15s (~%3sGB) | %-15s\n" "$id" "${NAME:0:18}" "$STATE" "$DISK_GB" "$SR_NAME" "$SR_FREE_GB" "$MSG_VIAVEL"
    
    UUIDS[$id]=$uuid
    NAMES[$id]=$NAME
    STATES[$id]=$STATE
    VIABILITY[$id]=$IS_VIABLE
    ((id++))
done

echo "--------------------------------------------------------------------------------------------------------------------"
log_msg "NOTA: 'REQ. DESLIGAR' significa que o storage está muito cheio para backup a quente."
echo ""

echo "Digite os números das VMs para backup (Ex: 1 3 4)"
read -p "Seleção: " selection
log_msg "Usuário selecionou IDs: $selection"

# ----------------------------------------
# 4. EXECUÇÃO DO BACKUP
# ----------------------------------------
echo ""
log_msg "[4/4] Iniciando Processo de Backup..."

SUCCESS_COUNT=0
FAIL_COUNT=0

for vm_id in $selection; do
    UUID=${UUIDS[$vm_id]}
    VM_NAME=${NAMES[$vm_id]}
    STATE=${STATES[$vm_id]}
    IS_VIABLE=${VIABILITY[$vm_id]}
    
    if [ -z "$UUID" ]; then
        continue
    fi

    SAFE_NAME=$(echo "$VM_NAME" | tr -d '[:cntrl:]' | tr -s ' ' '_' | tr -cd '[:alnum:]_.-')
    FILE_NAME="${MOUNT_POINT}/${SAFE_NAME}_${DATE_NOW}.xva"

    log_msg "------------------------------------------------"
    log_msg ">>> Processando: $VM_NAME ($STATE)"
    
    # Aviso de risco se o usuário tentar fazer backup de VM sem espaço
    if [ "$STATE" == "running" ] && [ "$IS_VIABLE" = false ]; then
        log_msg "    [ALERTA] Storage quase cheio! Tentativa de snapshot pode falhar."
        log_msg "    Recomendação: Cancele e desligue a VM antes de tentar."
        log_msg "    Tentando mesmo assim em 3 segundos..."
        sleep 3
    fi
    
    START_TIME=$(date +%s)
    EXPORT_ERROR=0

    if [ "$STATE" == "halted" ]; then
        log_msg "    Modo: Exportação Direta (Seguro para disco cheio)"
        xe vm-export vm=$UUID filename="$FILE_NAME" >> "$TEMP_LOG" 2>&1 &
        EXPORT_PID=$!
        monitor_export $EXPORT_PID "$FILE_NAME"
        wait $EXPORT_PID || EXPORT_ERROR=1
    else
        log_msg "    1. Criando snapshot temporário..."
        SNAP_UUID=$(xe vm-snapshot uuid=$UUID new-name-label="BACKUP_TEMP_SNAP" 2>&1)
        SNAP_RET=$?
        
        if [ $SNAP_RET -ne 0 ] || [[ "$SNAP_UUID" == *"Error"* ]]; then
            log_msg "    [ERRO CRÍTICO] Falha ao criar snapshot (Storage Cheio?)."
            log_msg "    Ação: Desligue a VM e tente novamente."
            ((FAIL_COUNT++))
            continue
        fi
        
        log_msg "    2. Convertendo snapshot em VM temporária..."
        TEMP_VM_UUID=$(xe vm-clone uuid=$SNAP_UUID new-name-label="BACKUP_TEMP_VM")
        xe vm-param-set uuid=$TEMP_VM_UUID is-a-template=false 2>/dev/null
        
        log_msg "    3. Exportando (Aguarde)..."
        xe vm-export vm=$TEMP_VM_UUID filename="$FILE_NAME" >> "$TEMP_LOG" 2>&1 &
        EXPORT_PID=$!
        monitor_export $EXPORT_PID "$FILE_NAME"
        wait $EXPORT_PID || EXPORT_ERROR=1
        
        log_msg "    4. Limpando temporários..."
        xe vm-uninstall uuid=$TEMP_VM_UUID force=true >> "$TEMP_LOG" 2>&1
        xe snapshot-uninstall uuid=$SNAP_UUID force=true >> "$TEMP_LOG" 2>&1
    fi

    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))

    if [ $EXPORT_ERROR -eq 0 ] && [ -f "$FILE_NAME" ]; then
        FSIZE=$(ls -lh "$FILE_NAME" | awk '{print $5}')
        log_msg "    [SUCESSO] Arquivo: $SAFE_NAME.xva"
        log_msg "    [DETALHES] Tamanho: $FSIZE | Tempo: ${DURATION}s"
        ((SUCCESS_COUNT++))
    else
        log_msg "    [ERRO] Falha ao exportar VM $VM_NAME."
        ((FAIL_COUNT++))
    fi
done

log_msg "------------------------------------------------"
log_msg "RESUMO FINAL:"
log_msg "Sucessos: $SUCCESS_COUNT"
log_msg "Falhas:   $FAIL_COUNT"
log_msg "------------------------------------------------"

log_msg "Salvando logs..."
cp "$TEMP_LOG" "$SCRIPT_DIR/$LOG_FILENAME"
cp "$TEMP_LOG" "$MOUNT_POINT/$LOG_FILENAME"

# ----------------------------------------
# 5. FINALIZAÇÃO
# ----------------------------------------
if [[ "$AUTO_UNMOUNT" =~ ^[sS]$ ]]; then
    echo ""
    log_msg "Desmontando disco (Automático)..."
    umount $MOUNT_POINT
    log_msg "Processo concluído. Pode remover o disco."
else
    echo ""
    log_msg "AVISO: O disco PERMANECE MONTADO (Opção do usuário)."
    ls -lh "$MOUNT_POINT"
fi