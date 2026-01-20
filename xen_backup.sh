#!/bin/bash
# ==========================================
# WIZARD DE BACKUP XENSERVER - V3.0 (DETAILED)
# ==========================================

MOUNT_POINT="/mnt/usb_backup_wizard"
DATE_NOW=$(date +%Y-%m-%d)

clear
echo "=========================================="
echo "   WIZARD DE EXPORTAÇÃO XENSERVER -> USB  "
echo "=========================================="

# ----------------------------------------
# 1. DETECÇÃO E MONTAGEM DO USB
# ----------------------------------------
echo ""
echo "[1/4] Detectando armazenamento..."

# Limpa lista anterior
> /tmp/disk_list

# Lista discos sd* excluindo o sda (sistema)
lsblk -d -n -o NAME,SIZE,MODEL,TRAN | grep -v "sda" | grep "sd" | while read -r line; do
    echo "$line" >> /tmp/disk_list
done

if [ ! -s /tmp/disk_list ]; then
    echo "ERRO: Nenhum disco USB detectado (apenas sda encontrado)."
    exit 1
fi

# Mostra opções numeradas
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
    echo "Opção inválida. Saindo."
    exit 1
fi

echo ">> Selecionado: $USB_DEVICE"
echo ""

# ----------------------------------------
# 2. MONTAGEM
# ----------------------------------------
echo "[2/4] Configuração de Montagem"
if mountpoint -q $MOUNT_POINT; then
    umount $MOUNT_POINT
fi

read -p "Deseja FORMATAR este disco AGORA? (Digite 'n' se já formatou) [s/N]: " format_opt

mkdir -p $MOUNT_POINT

if [[ "$format_opt" =~ ^[sS]$ ]]; then
    echo "!!! ATENÇÃO: DADOS EM $USB_DEVICE SERÃO APAGADOS !!!"
    read -p "Digite 'SIM' para confirmar: " confirm
    if [ "$confirm" == "SIM" ]; then
        echo "Formatando..."
        mkfs.ext4 -F "$USB_DEVICE" > /dev/null 2>&1
        mount "$USB_DEVICE" $MOUNT_POINT
    else
        echo "Cancelado."
        exit 0
    fi
else
    # Tenta montar sde1, se falhar tenta sde
    if [ -b "${USB_DEVICE}1" ]; then
        mount "${USB_DEVICE}1" $MOUNT_POINT 2>/dev/null || mount "$USB_DEVICE" $MOUNT_POINT
    else
        mount "$USB_DEVICE" $MOUNT_POINT
    fi
fi

if ! mountpoint -q $MOUNT_POINT; then
    echo "ERRO: Falha ao montar. Remova e insira o USB novamente."
    exit 1
fi

FREE_SPACE=$(df -h $MOUNT_POINT | awk 'NR==2 {print $4}')
echo ">> Disco pronto (Livre: $FREE_SPACE)"

# ----------------------------------------
# 3. LISTAGEM DETALHADA DE VMS
# ----------------------------------------
echo ""
echo "[3/4] Carregando detalhes das VMs (Aguarde...)"
echo "---------------------------------------------------------------------------------"
printf "%-3s | %-20s | %-10s | %-10s | %-15s\n" "ID" "NOME" "STATUS" "HW (C/M)" "DISCO TOTAL"
echo "---------------------------------------------------------------------------------"

# Arrays para armazenar dados
declare -a UUIDS
declare -a NAMES
declare -a STATES

# Pega lista crua de UUIDs (sem control domain e sem snapshots)
VM_UUID_LIST=$(xe vm-list is-control-domain=false is-a-snapshot=false params=uuid --minimal | tr ',' ' ')

id=1
for uuid in $VM_UUID_LIST; do
    # Coleta dados individuais para precisão
    NAME=$(xe vm-param-get uuid=$uuid param-name=name-label)
    STATE=$(xe vm-param-get uuid=$uuid param-name=power-state)
    VCPUS=$(xe vm-param-get uuid=$uuid param-name=VCPUs-max)
    MEM_BYTES=$(xe vm-param-get uuid=$uuid param-name=memory-static-max)
    MEM_GB=$((MEM_BYTES / 1024 / 1024 / 1024))
    
    # Calcula tamanho total dos discos virtuais (VBDs)
    DISK_SIZE_BYTES=0
    VBD_LIST=$(xe vbd-list vm-uuid=$uuid type=Disk params=vdi-uuid --minimal | tr ',' ' ')
    for vdi in $VBD_LIST; do
        if [ -n "$vdi" ]; then
            SIZE=$(xe vdi-param-get uuid=$vdi param-name=virtual-size 2>/dev/null)
            DISK_SIZE_BYTES=$((DISK_SIZE_BYTES + SIZE))
        fi
    done
    DISK_GB=$((DISK_SIZE_BYTES / 1024 / 1024 / 1024))

    # Formata a saída
    printf "%-3s | %-20s | %-10s | %-2s vCPU/%-2sGB | ~%-3s GB\n" "$id" "${NAME:0:20}" "$STATE" "$VCPUS" "$MEM_GB" "$DISK_GB"
    
    # Salva nos arrays
    UUIDS[$id]=$uuid
    NAMES[$id]=$NAME
    STATES[$id]=$STATE
    ((id++))
done

echo "---------------------------------------------------------------------------------"
echo "Legenda HW: C=Cores(CPU), M=Memória RAM"
echo ""

echo "Digite os números das VMs para backup (Ex: 1 3 4)"
read -p "Seleção: " selection

# ----------------------------------------
# 4. EXECUÇÃO DO BACKUP
# ----------------------------------------
echo ""
echo "[4/4] Iniciando Backup..."

for vm_id in $selection; do
    UUID=${UUIDS[$vm_id]}
    VM_NAME=${NAMES[$vm_id]}
    STATE=${STATES[$vm_id]}
    
    if [ -z "$UUID" ]; then
        echo ">> ID $vm_id inválido."
        continue
    fi

    SAFE_NAME=$(echo "$VM_NAME" | tr -d '[:cntrl:]' | tr -s ' ' '_' | tr -cd '[:alnum:]_.-')
    FILE_NAME="${MOUNT_POINT}/${SAFE_NAME}_${DATE_NOW}.xva"

    echo ">>> Processando: $VM_NAME ($STATE)"
    
    START_TIME=$(date +%s)

    if [ "$STATE" == "halted" ]; then
        xe vm-export vm=$UUID filename="$FILE_NAME"
    else
        echo "    Criando snapshot temporário..."
        SNAP_UUID=$(xe vm-snapshot uuid=$UUID new-name-label="BACKUP_TEMP_WIZARD")
        
        echo "    Exportando (Isso demora dependendo do tamanho)..."
        xe vm-export snapshot-uuid=$SNAP_UUID filename="$FILE_NAME"
        
        echo "    Limpando snapshot..."
        xe snapshot-uninstall uuid=$SNAP_UUID force=true
    fi

    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))

    if [ -f "$FILE_NAME" ]; then
        echo "    [OK] Backup salvo em ${DURATION}s."
    else
        echo "    [ERRO] Falha ao criar arquivo."
    fi
done

echo ""
echo "Concluído. Desmontando..."
umount $MOUNT_POINT
echo "Pode remover o disco."