#!/bin/bash
# ==========================================
# WIZARD DE AUDITORIA TOTAL XENSERVER - V2.0
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
log_msg "   WIZARD DE AUDITORIA (HOST + VMS) V2.0  "
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
# CORREÇÃO DO ENTER: Define 'n' como padrão se estiver vazio
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

# Cria pasta organizada
AUDIT_DIR="$MOUNT_POINT/AUDITORIA_$DATE_NOW"
mkdir -p "$AUDIT_DIR"

# ----------------------------------------
# 3. EXTRAÇÃO DE DADOS DO SERVIDOR (HOST)
# ----------------------------------------
echo ""
log_msg "[3/4] Coletando Dados do Servidor (Host Físico)..."

# Lista Hosts (geralmente é um, mas previne erro em pool)
HOST_UUID_LIST=$(xe host-list params=uuid --minimal | tr ',' ' ')

for host_uuid in $HOST_UUID_LIST; do
    HOSTNAME=$(xe host-param-get uuid=$host_uuid param-name=name-label)
    FILE_HOST="$AUDIT_DIR/SERVER_${HOSTNAME}_INFO.txt"
    
    log_msg ">>> Auditando Host: $HOSTNAME"
    
    echo "=================================================================" > "$FILE_HOST"
    echo " RELATÓRIO DO SERVIDOR FÍSICO: $HOSTNAME" >> "$FILE_HOST"
    echo " UUID: $host_uuid" >> "$FILE_HOST"
    echo " DATA: $DATE_NOW" >> "$FILE_HOST"
    echo "=================================================================" >> "$FILE_HOST"
    
    echo "--- [1] INFO GERAL E VERSÃO ---" >> "$FILE_HOST"
    xe host-list uuid=$host_uuid params=all >> "$FILE_HOST"
    
    echo "" >> "$FILE_HOST"
    echo "--- [2] CPUs E HARDWARE ---" >> "$FILE_HOST"
    xe host-cpu-list host-uuid=$host_uuid params=all >> "$FILE_HOST"
    
    echo "" >> "$FILE_HOST"
    echo "--- [3] PLACAS DE REDE FÍSICAS (PIFs) ---" >> "$FILE_HOST"
    xe pif-list host-uuid=$host_uuid params=all >> "$FILE_HOST"
    
    echo "" >> "$FILE_HOST"
    echo "--- [4] PATCHES INSTALADOS ---" >> "$FILE_HOST"
    xe patch-list hosts:contains=$host_uuid >> "$FILE_HOST"
    
    echo "" >> "$FILE_HOST"
    echo "--- [5] PARAM-LIST COMPLETO ---" >> "$FILE_HOST"
    xe host-param-list uuid=$host_uuid >> "$FILE_HOST"
done

# ----------------------------------------
# 4. EXTRAÇÃO DE DADOS DAS VMS
# ----------------------------------------
echo ""
log_msg "[4/4] Coletando Dados das VMs..."

VM_UUID_LIST=$(xe vm-list is-control-domain=false is-a-snapshot=false params=uuid --minimal | tr ',' ' ')
COUNT=0

for uuid in $VM_UUID_LIST; do
    NAME=$(xe vm-param-get uuid=$uuid param-name=name-label)
    SAFE_NAME=$(echo "$NAME" | tr -d '[:cntrl:]' | tr -s ' ' '_' | tr -cd '[:alnum:]_.-')
    FILE_OUT="$AUDIT_DIR/VM_${SAFE_NAME}_INFO.txt"
    
    log_msg ">>> Auditando VM: $NAME"
    
    echo "=================================================================" > "$FILE_OUT"
    echo " RELATÓRIO TÉCNICO COMPLETO: $NAME" >> "$FILE_OUT"
    echo " UUID: $uuid" >> "$FILE_OUT"
    echo " DATA: $DATE_NOW" >> "$FILE_OUT"
    echo "=================================================================" >> "$FILE_OUT"
    
    echo "--- [1] RESUMO GERAL ---" >> "$FILE_OUT"
    xe vm-list uuid=$uuid params=all >> "$FILE_OUT"
    
    echo "" >> "$FILE_OUT"
    echo "--- [2] PARÂMETROS COMPLETOS ---" >> "$FILE_OUT"
    xe vm-param-list uuid=$uuid >> "$FILE_OUT"
    
    echo "" >> "$FILE_OUT"
    echo "--- [3] DISCOS (VBDs) ---" >> "$FILE_OUT"
    VBD_LIST=$(xe vbd-list vm-uuid=$uuid params=uuid --minimal | tr ',' ' ')
    for vbd in $VBD_LIST; do
         echo "[VBD: $vbd]" >> "$FILE_OUT"
         xe vbd-param-list uuid=$vbd >> "$FILE_OUT"
    done
    
    echo "" >> "$FILE_OUT"
    echo "--- [4] REDES (VIFs) ---" >> "$FILE_OUT"
    VIF_LIST=$(xe vif-list vm-uuid=$uuid params=uuid --minimal | tr ',' ' ')
    for vif in $VIF_LIST; do
         echo "[VIF: $vif]" >> "$FILE_OUT"
         xe vif-param-list uuid=$vif >> "$FILE_OUT"
    done
    
    log_msg "    [OK] Salvo."
    ((COUNT++))
done

log_msg "------------------------------------------------"
log_msg "Auditoria finalizada. $COUNT VMs + Hosts auditados."

# Copia log para o HD
cp "$TEMP_LOG" "$AUDIT_DIR/auditoria_log.txt"

# ----------------------------------------
# 5. FINALIZAÇÃO (MANTER MONTADO?)
# ----------------------------------------
echo ""
log_msg "O processo de escrita terminou."
read -p "Deseja DESMONTAR o disco agora e remover com segurança? [S/n]: " umount_opt
# Padrão = Sim (S)
umount_opt=${umount_opt:-S}

if [[ "$umount_opt" =~ ^[sS]$ ]]; then
    log_msg "Desmontando disco..."
    umount $MOUNT_POINT
    log_msg "Disco desmontado. Pode remover o dispositivo."
else
    log_msg "------------------------------------------------"
    log_msg "AVISO: O disco PERMANECE MONTADO em:"
    log_msg "-> $AUDIT_DIR"
    log_msg "------------------------------------------------"
    echo "Listando arquivos gerados:"
    echo ""
    # Lista arquivos com tamanho legível e data
    ls -lh --time-style=long-iso "$AUDIT_DIR"
    echo ""
    log_msg "ATENÇÃO: Lembre-se de rodar 'umount $MOUNT_POINT' antes de remover o USB."
fi