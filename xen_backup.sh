#!/bin/bash
# ==========================================
# WIZARD DE BACKUP XENSERVER - V11.0 (SAFE DESTROY)
# ==========================================

# Configurações Iniciais
MOUNT_POINT="/mnt/usb_backup_wizard"
DATE_NOW=$(date +%Y-%m-%d_%H-%M)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILENAME="backup_log_${DATE_NOW}.txt"
TEMP_LOG="/tmp/${LOG_FILENAME}"
SNAPSHOT_SAFE_MARGIN=5  # Margem de segurança em GB

# Trap para Ctrl+C
trap ctrl_c INT
function ctrl_c() {
    echo ""
    log_msg "[!] Interrupção pelo usuário (Ctrl+C)."
    log_msg "[!] Tentando desmontar disco..."
    umount -l $MOUNT_POINT 2>/dev/null
    log_msg "[!] Saindo. Execute novamente para limpeza segura."
    exit 1
}

# Função de Log
log_msg() {
    local msg="$1"
    echo "$msg"
    echo "[$(date '+%H:%M:%S')] $msg" >> "$TEMP_LOG"
}

# Função de Limpeza Segura (A MUDANÇA CRÍTICA)
safe_cleanup() {
    local vm_uuid=$1
    local snap_uuid=$2
    
    # 1. Destrói o registro da VM Temporária (NÃO TOCA EM DISCO)
    if [ -n "$vm_uuid" ]; then
        log_msg "    Removendo registro da VM Temp (Metadata)..."
        xe vm-destroy uuid=$vm_uuid >> "$TEMP_LOG" 2>&1
    fi
    
    # 2. Remove o Snapshot (Isso libera o espaço de forma segura)
    if [ -n "$snap_uuid" ]; then
        log_msg "    Removendo Snapshot..."
        xe snapshot-uninstall uuid=$snap_uuid force=true >> "$TEMP_LOG" 2>&1
    fi
}

# Monitoramento
monitor_export() {
    local pid=$1
    local file=$2
    local delay=3
    echo "    (Monitorando progresso...)"
    while kill -0 $pid 2>/dev/null; do
        if [ -f "$file" ]; then
            current_size=$(ls -lh "$file" | awk '{print $5}')
            if [ -n "$current_size" ]; then
                printf "    >> Tamanho Atual: %-10s\r" "$current_size"
            fi
        fi
        sleep $delay
    done
    echo ""
}

clear
log_msg "=========================================="
log_msg "   WIZARD DE BACKUP XENSERVER - V11.0     "
log_msg "=========================================="
log_msg "Data: $DATE_NOW"

# ----------------------------------------
# 0. ROTINA DE AUTO-LIMPEZA SEGURA
# ----------------------------------------
log_msg "[0/4] Verificando ambiente..."

ORPHAN_VMS=$(xe vm-list name-label="BACKUP_TEMP_VM" params=uuid --minimal)
ORPHAN_SNAPS=$(xe snapshot-list name-label="BACKUP_TEMP_SNAP" params=uuid --minimal)

if [ -n "$ORPHAN_VMS" ] || [ -n "$ORPHAN_SNAPS" ]; then
    log_msg "[AVISO] Encontrados resíduos anteriores."
    read -p "Deseja limpar resíduos agora? [S/n]: " clean_opt
    clean_opt=${clean_opt:-S}
    if [[ "$clean_opt" =~ ^[sS]$ ]]; then
        # Limpa VMs usando vm-destroy (seguro)
        for u in ${ORPHAN_VMS//,/ }; do 
            safe_cleanup "$u" ""
        done
        # Limpa Snapshots
        for u in ${ORPHAN_SNAPS//,/ }; do 
            safe_cleanup "" "$u"
        done
        log_msg "Limpeza concluída."
    fi
fi

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
# 2. MONTAGEM INTELIGENTE
# ----------------------------------------
log_msg "[2/4] Configuração de Montagem"

CURRENT_MOUNT=$(lsblk -n -o MOUNTPOINT $USB_DEVICE | head -n 1)
if [ -n "$CURRENT_MOUNT" ]; then
    log_msg "AVISO: Dispositivo já montado em: $CURRENT_MOUNT"
    log_msg "Desmontando para evitar conflitos..."
    umount -l $USB_DEVICE 2>/dev/null
    umount -l $CURRENT_MOUNT 2>/dev/null
fi

if mountpoint -q $MOUNT_POINT; then
    umount -l $MOUNT_POINT 2>/dev/null
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
    log_msg "ERRO CRÍTICO: Falha ao montar."
    exit 1
fi

FREE_SPACE=$(df -h $MOUNT_POINT | awk 'NR==2 {print $4}')
log_msg ">> Disco montado (Livre: $FREE_SPACE)"

echo ""
read -p "Deseja DESMONTAR automaticamente ao final? [S/n]: " auto_unmount_opt
AUTO_UNMOUNT=${auto_unmount_opt:-S}

# ----------------------------------------
# 3. ANÁLISE DE VMS
# ----------------------------------------
echo ""
log_msg "[3/4] Analisando VMs..."
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
    if [[ "$NAME" == "BACKUP_TEMP_VM" ]]; then continue; fi
    
    STATE=$(xe vm-param-get uuid=$uuid param-name=power-state)
    
    # Tamanho e Storage
    DISK_SIZE_BYTES=0
    SR_NAME="N/A"
    SR_FREE_GB=0
    
    VBD_LIST=$(xe vbd-list vm-uuid=$uuid type=Disk params=vdi-uuid --minimal | tr ',' ' ')
    FIRST=true
    for vdi in $VBD_LIST; do
        if [ -n "$vdi" ]; then
            SIZE=$(xe vdi-param-get uuid=$vdi param-name=virtual-size 2>/dev/null)
            DISK_SIZE_BYTES=$((DISK_SIZE_BYTES + SIZE))
            if [ "$FIRST" = true ]; then
                SR_UUID=$(xe vdi-param-get uuid=$vdi param-name=sr-uuid 2>/dev/null)
                if [ -n "$SR_UUID" ]; then
                    SR_NAME_RAW=$(xe sr-param-get uuid=$SR_UUID param-name=name-label 2>/dev/null)
                    SR_NAME="${SR_NAME_RAW:0:15}"
                    P_SIZE=$(xe sr-param-get uuid=$SR_UUID param-name=physical-size 2>/dev/null)
                    P_UTIL=$(xe sr-param-get uuid=$SR_UUID param-name=physical-utilisation 2>/dev/null)
                    if [ -n "$P_SIZE" ] && [ -n "$P_UTIL" ]; then
                         FREE_BYTES=$((P_SIZE - P_UTIL))
                         SR_FREE_GB=$((FREE_BYTES / 1024 / 1024 / 1024))
                    fi
                fi
                FIRST=false
            fi
        fi
    done
    DISK_GB=$((DISK_SIZE_BYTES / 1024 / 1024 / 1024))

    MSG_VIAVEL="ERRO"
    IS_VIABLE=true
    
    if [ "$STATE" == "halted" ]; then
        MSG_VIAVEL="OK (DIRETO)"
    else
        if [ "$SR_FREE_GB" -lt "$SNAPSHOT_SAFE_MARGIN" ]; then
            MSG_VIAVEL="REQ. DESLIGAR"
            IS_VIABLE=false
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

echo "Digite os números das VMs para backup (Ex: 1 3 4)"
read -p "Seleção: " selection

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
    
    if [ -z "$UUID" ]; then continue; fi

    SAFE_NAME=$(echo "$VM_NAME" | tr -d '[:cntrl:]' | tr -s ' ' '_' | tr -cd '[:alnum:]_.-')
    FILE_NAME="${MOUNT_POINT}/${SAFE_NAME}_${DATE_NOW}.xva"
    FORCE_SHUTDOWN=false

    log_msg "------------------------------------------------"
    log_msg ">>> Processando: $VM_NAME ($STATE)"
    
    # Validação de espaço
    if [ "$STATE" == "running" ] && [ "$IS_VIABLE" = false ]; then
        log_msg "    [ALERTA] Storage cheio. Snapshot arriscado."
        read -p "    Deseja DESLIGAR a VM para backup seguro? [y/N]: " shut_opt
        if [[ "$shut_opt" =~ ^[yY]$ ]]; then
            FORCE_SHUTDOWN=true
        else
            log_msg "    Pulando VM."
            ((FAIL_COUNT++))
            continue
        fi
    fi

    START_TIME=$(date +%s)
    EXPORT_ERROR=0

    # EXECUÇÃO
    if [ "$STATE" == "halted" ] || [ "$FORCE_SHUTDOWN" = true ]; then
        # MODO OFF-LINE
        if [ "$FORCE_SHUTDOWN" = true ]; then
            log_msg "    1. Desligando VM..."
            xe vm-shutdown uuid=$UUID
            sleep 2
            # Garante Force se travar
            if [ "$(xe vm-param-get uuid=$UUID param-name=power-state)" != "halted" ]; then
                xe vm-shutdown uuid=$UUID force=true
            fi
        fi

        log_msg "    2. Exportando Direto..."
        xe vm-export vm=$UUID filename="$FILE_NAME" >> "$TEMP_LOG" 2>&1 &
        EXPORT_PID=$!
        monitor_export $EXPORT_PID "$FILE_NAME"
        wait $EXPORT_PID || EXPORT_ERROR=1

        if [ "$FORCE_SHUTDOWN" = true ]; then
            log_msg "    3. Religando VM..."
            xe vm-start uuid=$UUID
        fi

    else
        # MODO ONLINE (SNAPSHOT)
        log_msg "    1. Criando snapshot..."
        SNAP_UUID=$(xe vm-snapshot uuid=$UUID new-name-label="BACKUP_TEMP_SNAP" 2>&1)
        SNAP_RET=$?

        if [ $SNAP_RET -ne 0 ]; then
            log_msg "    [FALHA NO SNAPSHOT] Erro de Storage."
            read -p "    Tentar método DESLIGAR a VM? [y/N]: " retry_opt
            if [[ "$retry_opt" =~ ^[yY]$ ]]; then
                log_msg "    -> Alternando para Shutdown..."
                xe vm-shutdown uuid=$UUID
                xe vm-export vm=$UUID filename="$FILE_NAME" >> "$TEMP_LOG" 2>&1 &
                EXPORT_PID=$!
                monitor_export $EXPORT_PID "$FILE_NAME"
                wait $EXPORT_PID || EXPORT_ERROR=1
                xe vm-start uuid=$UUID
            else
                ((FAIL_COUNT++))
                continue
            fi
        else
            log_msg "    2. Clonando para VM Temp..."
            TEMP_VM_UUID=$(xe vm-clone uuid=$SNAP_UUID new-name-label="BACKUP_TEMP_VM")
            xe vm-param-set uuid=$TEMP_VM_UUID is-a-template=false 2>/dev/null
            
            log_msg "    3. Exportando..."
            xe vm-export vm=$TEMP_VM_UUID filename="$FILE_NAME" >> "$TEMP_LOG" 2>&1 &
            EXPORT_PID=$!
            monitor_export $EXPORT_PID "$FILE_NAME"
            wait $EXPORT_PID || EXPORT_ERROR=1
            
            log_msg "    4. Limpando..."
            # USO DA FUNÇÃO SEGURA
            safe_cleanup "$TEMP_VM_UUID" "$SNAP_UUID"
        fi
    fi

    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))

    if [ $EXPORT_ERROR -eq 0 ] && [ -f "$FILE_NAME" ]; then
        FSIZE=$(ls -lh "$FILE_NAME" | awk '{print $5}')
        log_msg "    [SUCESSO] Arquivo: $SAFE_NAME.xva ($FSIZE)"
        ((SUCCESS_COUNT++))
    else
        log_msg "    [ERRO] Falha na exportação."
        ((FAIL_COUNT++))
    fi
done

log_msg "------------------------------------------------"
log_msg "RESUMO: Sucessos: $SUCCESS_COUNT | Falhas: $FAIL_COUNT"

cp "$TEMP_LOG" "$SCRIPT_DIR/$LOG_FILENAME"
cp "$TEMP_LOG" "$MOUNT_POINT/$LOG_FILENAME"

if [[ "$AUTO_UNMOUNT" =~ ^[sS]$ ]]; then
    log_msg "Desmontando..."
    umount $MOUNT_POINT
    log_msg "Pronto. Remova o disco."
else
    log_msg "AVISO: Disco mantido montado."
fi