#!/bin/bash
# ==========================================
# WIZARD DE BACKUP XENSERVER - V2.0 (CORRIGIDO)
# ==========================================

MOUNT_POINT="/mnt/usb_backup_wizard"
DATE_NOW=$(date +%Y-%m-%d)
TMP_LIST="/tmp/vm_list.csv"

clear
echo "=========================================="
echo "   WIZARD DE EXPORTAÇÃO XENSERVER -> USB  "
echo "=========================================="

# ----------------------------------------
# 1. DETECÇÃO E MONTAGEM DO USB
# ----------------------------------------
echo ""
echo "[1/4] Detectando discos disponíveis (ignorando disco do sistema)..."
echo "----------------------------------------------------------------"

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

echo ">> Você selecionou: $USB_DEVICE"
echo ""

# ----------------------------------------
# 2. MONTAGEM (COM OU SEM FORMATAÇÃO)
# ----------------------------------------
echo "[2/4] Configuração de Arquivos"
# Verifica se já está montado para evitar erro
if mountpoint -q $MOUNT_POINT; then
    umount $MOUNT_POINT
fi

read -p "Deseja FORMATAR este disco AGORA? (Digite 'n' se já formatou antes) [s/N]: " format_opt

mkdir -p $MOUNT_POINT

if [[ "$format_opt" =~ ^[sS]$ ]]; then
    echo "!!! ATENÇÃO: TODOS OS DADOS EM $USB_DEVICE SERÃO APAGADOS !!!"
    read -p "Tem certeza absoluta? Digite 'SIM' para confirmar: " confirm
    if [ "$confirm" == "SIM" ]; then
        echo "Formatando..."
        mkfs.ext4 -F "$USB_DEVICE" > /dev/null 2>&1
        mount "$USB_DEVICE" $MOUNT_POINT
    else
        echo "Cancelado."
        exit 0
    fi
else
    echo "Montando disco existente..."
    # Tenta montar sde1, se falhar tenta sde
    if [ -b "${USB_DEVICE}1" ]; then
        mount "${USB_DEVICE}1" $MOUNT_POINT 2>/dev/null || mount "$USB_DEVICE" $MOUNT_POINT
    else
        mount "$USB_DEVICE" $MOUNT_POINT
    fi
fi

# Verificação final de montagem
if ! mountpoint -q $MOUNT_POINT; then
    echo "ERRO CRÍTICO: Não foi possível montar o disco."
    echo "Se você acabou de formatar, tente remover e inserir o USB novamente."
    exit 1
fi

FREE_SPACE=$(df -h $MOUNT_POINT | awk 'NR==2 {print $4}')
echo ">> Sucesso! Disco montado (Livre: $FREE_SPACE)"

# ----------------------------------------
# 3. SELEÇÃO DE VMS (MÉTODO SEGURO)
# ----------------------------------------
echo ""
echo "[3/4] Listando Máquinas Virtuais..."
echo "----------------------------------------------------------------"
echo "ID  | ESTADO    | NOME DA VM"
echo "--- | --------- | ------------------------"

# Obtém lista limpa separada por vírgulas: uuid,name-label,power-state
xe vm-list is-control-domain=false is-a-snapshot=false params=uuid,name-label,power-state --minimal > $TMP_LIST

# Arrays para armazenar dados
declare -a UUIDS
declare -a NAMES
declare -a STATES

id=1
# Lê o arquivo CSV gerado pelo XenServer
# IFS=, define a vírgula como separador
while IFS=, read -r uuid name state; do
    # Remove aspas se houver
    name=$(echo $name | sed 's/"//g')
    
    printf "%-3s | %-9s | %s\n" "$id" "$state" "$name"
    
    UUIDS[$id]=$uuid
    NAMES[$id]=$name
    STATES[$id]=$state
    ((id++))
done < $TMP_LIST

echo ""
echo "Digite os números das VMs para backup separados por espaço (Ex: 1 3 4)"
read -p "Seleção: " selection

# ----------------------------------------
# 4. EXECUÇÃO DO BACKUP
# ----------------------------------------
echo ""
echo "[4/4] Iniciando Processo de Backup..."

for vm_id in $selection; do
    UUID=${UUIDS[$vm_id]}
    VM_NAME=${NAMES[$vm_id]}
    STATE=${STATES[$vm_id]}
    
    if [ -z "$UUID" ]; then
        echo ">> ID $vm_id inválido, pulando..."
        continue
    fi

    # Limpa nome do arquivo (remove espaços e caracteres estranhos)
    SAFE_NAME=$(echo "$VM_NAME" | tr -d '[:cntrl:]' | tr -s ' ' '_' | tr -cd '[:alnum:]_.-')
    FILE_NAME="${MOUNT_POINT}/${SAFE_NAME}_${DATE_NOW}.xva"

    echo "-------------------------------------------------------"
    echo "Processando: $VM_NAME"
    echo "Estado Atual: $STATE"
    
    START_TIME=$(date +%s)

    if [ "$STATE" == "halted" ]; then
        echo ">> Exportando VM Desligada (Modo Rápido)..."
        xe vm-export vm=$UUID filename="$FILE_NAME"
    else
        echo ">> VM Ligada detectada. Usando Snapshot temporário..."
        echo "   1. Criando snapshot..."
        SNAP_UUID=$(xe vm-snapshot uuid=$UUID new-name-label="BACKUP_TEMP_WIZARD")
        
        echo "   2. Exportando snapshot..."
        xe vm-export snapshot-uuid=$SNAP_UUID filename="$FILE_NAME"
        
        echo "   3. Deletando snapshot..."
        xe snapshot-uninstall uuid=$SNAP_UUID force=true
    fi

    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))

    if [ -f "$FILE_NAME" ]; then
        FSIZE=$(ls -lh "$FILE_NAME" | awk '{print $5}')
        echo ">> SUCESSO! Arquivo criado: $SAFE_NAME.xva ($FSIZE)"
        echo ">> Tempo total: ${DURATION} segundos"
    else
        echo ">> ERRO: O arquivo de backup não foi criado."
    fi
done

echo ""
echo "=========================================="
echo "Tarefas concluídas."
echo "Desmontando USB..."
umount $MOUNT_POINT
echo "Pode remover o disco."