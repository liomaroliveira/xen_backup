#!/bin/bash
# ==========================================
# WIZARD DE BACKUP XENSERVER - V6.0 (LOGGING)
# ==========================================

# Configurações Iniciais
MOUNT_POINT="/mnt/usb_backup_wizard"
DATE_NOW=$(date +%Y-%m-%d_%H-%M)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILENAME="backup_log_${DATE_NOW}.txt"
TEMP_LOG="/tmp/${LOG_FILENAME}"

# Função de Log (Exibe na tela e salva em arquivo temporário)
log_msg() {
    local msg="$1"
    echo "$msg"
    echo "[$(date '+%H:%M:%S')] $msg" >> "$TEMP_LOG"
}

clear
log_msg "=========================================="
log_msg "   WIZARD DE EXPORTAÇÃO XENSERVER -> USB  "
log_msg "=========================================="
log_msg "Iniciando script em: $DATE_NOW"

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

mkdir -p $MOUNT_POINT

if [[ "$format_opt" =~ ^[sS]$ ]]; then
    log_msg "!!! ATENÇÃO: DADOS EM $USB_DEVICE SERÃO APAGADOS !!!"
    read -p "Digite 'SIM' para confirmar: " confirm
    if [ "$confirm" == "SIM" ]; then
        log_msg "Formatando dispositivo..."
        mkfs.ext4 -F "$USB_DEVICE" >> "$TEMP_LOG" 2>&1
        mount "$USB_DEVICE" $MOUNT_POINT
    else
        log_msg "Cancelado pelo usuário."
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
log_msg ">> Disco montado com sucesso (Livre: $FREE_SPACE)"

# ----------------------------------------
# 3. LISTAGEM DETALHADA DE VMS
# ----------------------------------------
echo ""
log_msg "[3/4] Carregando detalhes das VMs..."
echo "--------------------------------------------------------------------------------------------------"
printf "%-3s | %-20s | %-8s | %-10s | %-12s | %-12s\n" "ID" "NOME" "STATUS" "HW (C/M)" "DISCO TOTAL" "DISCO EM USO"
echo "--------------------------------------------------------------------------------------------------"

declare -a UUIDS
declare -a NAMES
declare -a STATES

VM_UUID_LIST=$(xe vm-list is-control-domain=false is-a-snapshot=false params=uuid --minimal | tr ',' ' ')

id=1
for uuid in $VM_UUID_LIST; do
    NAME=$(xe vm-param-get uuid=$uuid param-name=name-label)
    STATE=$(xe vm-param-get uuid=$uuid param-name=power-state)
    VCPUS=$(xe vm-param-get uuid=$uuid param-name=VCPUs-max)
    MEM_BYTES=$(xe vm-param-get uuid=$uuid param-name=memory-static-max)
    MEM_GB=$((MEM_BYTES / 1024 / 1024 / 1024))
    
    DISK_SIZE_BYTES=0
    DISK_USED_BYTES=0
    
    VBD_LIST=$(xe vbd-list vm-uuid=$uuid type=Disk params=vdi-uuid --minimal | tr ',' ' ')
    for vdi in $VBD_LIST; do
        if [ -n "$vdi" ]; then
            SIZE=$(xe vdi-param-get uuid=$vdi param-name=virtual-size 2>/dev/null)
            DISK_SIZE_BYTES=$((DISK_SIZE_BYTES + SIZE))
            USED=$(xe vdi-param-get uuid=$vdi param-name=physical-utilisation 2>/dev/null)
            DISK_USED_BYTES=$((DISK_USED_BYTES + USED))
        fi
    done
    DISK_GB=$((DISK_SIZE_BYTES / 1024 / 1024 / 1024))
    USED_GB=$((DISK_USED_BYTES / 1024 / 1024 / 1024))

    printf "%-3s | %-20s | %-8s | %-2s vCPU/%-2sGB | ~%-4s GB    | ~%-4s GB\n" "$id" "${NAME:0:20}" "$STATE" "$VCPUS" "$MEM_GB" "$DISK_GB" "$USED_GB"
    
    UUIDS[$id]=$uuid
    NAMES[$id]=$NAME
    STATES[$id]=$STATE
    ((id++))
done

echo "--------------------------------------------------------------------------------------------------"

TOTAL_SR_FREE=0
SR_LVM_LIST=$(xe sr-list type=lvm params=uuid --minimal | tr ',' ' ')
for sr in $SR_LVM_LIST; do
    P_SIZE=$(xe sr-param-get uuid=$sr param-name=physical-size 2>/dev/null)
    P_UTIL=$(xe sr-param-get uuid=$sr param-name=physical-utilisation 2>/dev/null)
    if [ -n "$P_SIZE" ] && [ -n "$P_UTIL" ]; then
        FREE=$((P_SIZE - P_UTIL))
        TOTAL_SR_FREE=$((TOTAL_SR_FREE + FREE))
    fi
done
TOTAL_FREE_GB=$((TOTAL_SR_FREE / 1024 / 1024 / 1024))

log_msg "ESPAÇO LIVRE NO SERVIDOR (LVM): ~${TOTAL_FREE_GB} GB"
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
    
    if [ -z "$UUID" ]; then
        log_msg ">> ID $vm_id inválido. Pulando."
        continue
    fi

    SAFE_NAME=$(echo "$VM_NAME" | tr -d '[:cntrl:]' | tr -s ' ' '_' | tr -cd '[:alnum:]_.-')
    FILE_NAME="${MOUNT_POINT}/${SAFE_NAME}_${DATE_NOW}.xva"

    log_msg "------------------------------------------------"
    log_msg ">>> Processando: $VM_NAME ($STATE)"
    
    START_TIME=$(date +%s)
    EXPORT_ERROR=0

    if [ "$STATE" == "halted" ]; then
        log_msg "    Modo: Exportação Direta (Desligada)"
        xe vm-export vm=$UUID filename="$FILE_NAME" >> "$TEMP_LOG" 2>&1 || EXPORT_ERROR=1
    else
        log_msg "    1. Criando snapshot temporário..."
        SNAP_UUID=$(xe vm-snapshot uuid=$UUID new-name-label="BACKUP_TEMP_SNAP")
        
        log_msg "    2. Convertendo snapshot em VM temporária..."
        TEMP_VM_UUID=$(xe vm-clone uuid=$SNAP_UUID new-name-label="BACKUP_TEMP_VM")
        xe vm-param-set uuid=$TEMP_VM_UUID is-a-template=false 2>/dev/null
        
        log_msg "    3. Exportando (Aguarde)..."
        xe vm-export vm=$TEMP_VM_UUID filename="$FILE_NAME" >> "$TEMP_LOG" 2>&1 || EXPORT_ERROR=1
        
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
        log_msg "    [ERRO] Falha ao exportar VM $VM_NAME. Verifique o log."
        ((FAIL_COUNT++))
    fi
done

log_msg "------------------------------------------------"
log_msg "RESUMO FINAL:"
log_msg "Sucessos: $SUCCESS_COUNT"
log_msg "Falhas:   $FAIL_COUNT"
log_msg "------------------------------------------------"

# Salvar logs
log_msg "Salvando logs..."
cp "$TEMP_LOG" "$SCRIPT_DIR/$LOG_FILENAME"
cp "$TEMP_LOG" "$MOUNT_POINT/$LOG_FILENAME"

log_msg "Logs salvos em:"
log_msg "1. $SCRIPT_DIR/$LOG_FILENAME"
log_msg "2. USB: /$LOG_FILENAME"

echo ""
log_msg "Desmontando disco..."
umount $MOUNT_POINT
log_msg "Processo concluído. Pode remover o disco."