#!/bin/bash
# ==========================================
# WIZARD DE AUDITORIA TOTAL XENSERVER -> USB
# ==========================================

# Configurações Iniciais
MOUNT_POINT="/mnt/usb_audit_wizard"
DATE_NOW=$(date +%Y-%m-%d_%H-%M)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILENAME="audit_log_${DATE_NOW}.txt"
TEMP_LOG="/tmp/${LOG_FILENAME}"

# Função de Log
log_msg() {
    local msg="$1"
    echo "$msg"
    echo "[$(date '+%H:%M:%S')] $msg" >> "$TEMP_LOG"
}

clear
log_msg "=========================================="
log_msg "   WIZARD DE AUDITORIA DE VMS (INFO 100%) "
log_msg "=========================================="
log_msg "Data: $DATE_NOW"

# ----------------------------------------
# 1. DETECÇÃO E MONTAGEM DO USB
# ----------------------------------------
echo ""
log_msg "[1/3] Detectando armazenamento..."

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
log_msg "[2/3] Configuração de Montagem"
if mountpoint -q $MOUNT_POINT; then
    umount $MOUNT_POINT
fi

read -p "Deseja FORMATAR este disco para EXT4 AGORA? (Digite 'n' se já formatou) [s/N]: " format_opt

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

# ----------------------------------------
# 3. EXTRAÇÃO DE DADOS (LOOP TOTAL)
# ----------------------------------------
echo ""
log_msg "[3/3] Iniciando Extração Completa de Dados..."
log_msg "Este script irá varrer TODAS as VMs e salvar os dados em .txt individuais."

# Cria pasta organizada com a data
AUDIT_DIR="$MOUNT_POINT/AUDITORIA_$DATE_NOW"
mkdir -p "$AUDIT_DIR"

VM_UUID_LIST=$(xe vm-list is-control-domain=false is-a-snapshot=false params=uuid --minimal | tr ',' ' ')

COUNT=0

for uuid in $VM_UUID_LIST; do
    NAME=$(xe vm-param-get uuid=$uuid param-name=name-label)
    SAFE_NAME=$(echo "$NAME" | tr -d '[:cntrl:]' | tr -s ' ' '_' | tr -cd '[:alnum:]_.-')
    FILE_OUT="$AUDIT_DIR/${SAFE_NAME}_FULL_INFO.txt"
    
    log_msg "------------------------------------------------"
    log_msg ">>> Coletando dados de: $NAME"
    
    echo "=================================================================" > "$FILE_OUT"
    echo " RELATÓRIO TÉCNICO COMPLETO: $NAME" >> "$FILE_OUT"
    echo " UUID: $uuid" >> "$FILE_OUT"
    echo " DATA COLETA: $DATE_NOW" >> "$FILE_OUT"
    echo "=================================================================" >> "$FILE_OUT"
    echo "" >> "$FILE_OUT"
    
    echo "--- [1] RESUMO GERAL ---" >> "$FILE_OUT"
    xe vm-list uuid=$uuid params=all >> "$FILE_OUT"
    echo "" >> "$FILE_OUT"
    
    echo "--- [2] PARÂMETROS DETALHADOS (PARAM-LIST) ---" >> "$FILE_OUT"
    xe vm-param-list uuid=$uuid >> "$FILE_OUT"
    echo "" >> "$FILE_OUT"
    
    echo "--- [3] DISCOS VIRTUAIS (VBDs/VDIs) ---" >> "$FILE_OUT"
    # Lista VBDs associados e seus detalhes
    VBD_LIST=$(xe vbd-list vm-uuid=$uuid params=uuid --minimal | tr ',' ' ')
    for vbd in $VBD_LIST; do
         echo "  [VBD UUID: $vbd]" >> "$FILE_OUT"
         xe vbd-param-list uuid=$vbd >> "$FILE_OUT"
         echo "  ..." >> "$FILE_OUT"
    done
    echo "" >> "$FILE_OUT"

    echo "--- [4] INTERFACES DE REDE (VIFs) ---" >> "$FILE_OUT"
    # Lista VIFs associados e seus detalhes (MAC, Network, etc)
    VIF_LIST=$(xe vif-list vm-uuid=$uuid params=uuid --minimal | tr ',' ' ')
    for vif in $VIF_LIST; do
         echo "  [VIF UUID: $vif]" >> "$FILE_OUT"
         xe vif-param-list uuid=$vif >> "$FILE_OUT"
         echo "  ..." >> "$FILE_OUT"
    done
    echo "" >> "$FILE_OUT"
    
    echo "--- [5] SNAPSHOTS ASSOCIADOS ---" >> "$FILE_OUT"
    xe snapshot-list snapshot-of=$uuid >> "$FILE_OUT"
    
    log_msg "    [OK] Salvo em: $SAFE_NAME_FULL_INFO.txt"
    ((COUNT++))
done

log_msg "------------------------------------------------"
log_msg "Processo finalizado. $COUNT VMs auditadas."
log_msg "Arquivos salvos na pasta: AUDITORIA_$DATE_NOW"

# Copia log para o HD
cp "$TEMP_LOG" "$AUDIT_DIR/auditoria_log.txt"

echo ""
log_msg "Desmontando disco..."
umount $MOUNT_POINT
log_msg "Pode remover o disco."