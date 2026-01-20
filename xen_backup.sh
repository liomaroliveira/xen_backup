#!/bin/bash
# ==========================================
# WIZARD DE BACKUP XENSERVER - MODO TEXTO
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
echo "[1/4] Detectando discos disponíveis (ignorando disco do sistema)..."
echo "----------------------------------------------------------------"
# Lista discos sd* excluindo o sda (sistema)
lsblk -d -n -o NAME,SIZE,MODEL | grep -v "sda" | grep "sd" | awk '{print "/dev/"$1 " - Tamanho: " $2 " - " $3}' > /tmp/disk_list

if [ ! -s /tmp/disk_list ]; then
    echo "ERRO: Nenhum disco USB detectado (apenas sda encontrado)."
    echo "Conecte o HD externo e rode o script novamente."
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
USB_DEVICE=$(echo "$selected_disk_info" | awk '{print $1}')

if [ -z "$USB_DEVICE" ]; then
    echo "Opção inválida. Saindo."
    exit 1
fi

echo ">> Você selecionou: $USB_DEVICE"
echo ""

# ----------------------------------------
# 2. FORMATAÇÃO E MONTAGEM
# ----------------------------------------
echo "[2/4] Configuração de Arquivos"
read -p "Deseja FORMATAR este disco para ext4 (Recomendado para velocidade)? [s/N]: " format_opt

# Prepara ponto de montagem
mkdir -p $MOUNT_POINT
# Garante que nada está montado lá
umount $MOUNT_POINT 2>/dev/null

if [[ "$format_opt" =~ ^[sS]$ ]]; then
    echo "!!! ATENÇÃO: TODOS OS DADOS EM $USB_DEVICE SERÃO APAGADOS !!!"
    read -p "Tem certeza absoluta? Digite 'SIM' para confirmar: " confirm
    if [ "$confirm" == "SIM" ]; then
        echo "Formatando (pode demorar alguns segundos)..."
        mkfs.ext4 -F "$USB_DEVICE" > /dev/null 2>&1
        mount "$USB_DEVICE" $MOUNT_POINT
    else
        echo "Formatação cancelada. Tentando montar como está..."
        mount "$USB_DEVICE" $MOUNT_POINT
    fi
else
    echo "Tentando montar partição existente..."
    # Tenta montar a partição 1 (comum em HDs windows) ou o disco inteiro
    if [ -b "${USB_DEVICE}1" ]; then
        mount "${USB_DEVICE}1" $MOUNT_POINT
    else
        mount "$USB_DEVICE" $MOUNT_POINT
    fi
fi

# Verifica se montou
if ! mountpoint -q $MOUNT_POINT; then
    echo "ERRO: Não foi possível montar o disco. Se for NTFS, o XenServer pode não ter driver de escrita."
    echo "Recomendo rodar novamente e escolher a opção de FORMATAR para ext4."
    exit 1
fi

FREE_SPACE=$(df -h $MOUNT_POINT | awk 'NR==2 {print $4}')
echo ">> Sucesso! Disco montado em $MOUNT_POINT (Livre: $FREE_SPACE)"

# ----------------------------------------
# 3. SELEÇÃO DE VMS
# ----------------------------------------
echo ""
echo "[3/4] Listando Máquinas Virtuais..."
echo "----------------------------------------------------------------"

# Obtém lista de VMs (UUID e Nome) - Ignora Control Domain e Templates
xe vm-list is-control-domain=false is-a-snapshot=false params=uuid,name-label,power-state --minimal | tr ',' ' ' > /tmp/vm_raw_list

# Cria arrays para menu
declare -a VM_UUIDS
declare -a VM_NAMES
declare -a VM_STATES

i=1
# O comando xe vm-list separator é ruim de parsear com espaços no nome.
# Vamos usar um loop forçado linha a linha
xe vm-list is-control-domain=false is-a-snapshot=false params=name-label,power-state,uuid | grep -v "^$" | paste - - - | while read -r line; do
    # Formatação visual simples
    echo "$line" >> /tmp/vm_list_formatted
done

# Recarrega lista formatada para exibir e selecionar
# Devido à complexidade do Bash antigo do Xen, faremos uma iteração visual
echo "ID  | ESTADO    | NOME DA VM"
echo "--- | --------- | ------------------------"
id=1
# Arquivo temporário para guardar mapeamento ID -> UUID
> /tmp/vm_map

IFS=$'\n'
for vm in $(xe vm-list is-control-domain=false is-a-snapshot=false params=uuid,power-state,name-label | grep "uuid" -A 2 | grep -v "^--$"); do
    # Logica simplificada: captura blocos de 3 linhas
    # Mas para o script ser robusto no XenServer CLI, vamos usar uuid direto
    pass
done

# Método robusto de listagem
xe vm-list is-control-domain=false is-a-snapshot=false params=uuid,power-state,name-label | paste - - - | awk '{printf "%3d | %-9s | %s %s %s %s\n", NR, $4, $6, $7, $8, $9}' > /tmp/menu_display
xe vm-list is-control-domain=false is-a-snapshot=false params=uuid --minimal | tr ',' '\n' > /tmp/uuid_list

cat /tmp/menu_display

echo ""
echo "Digite os números das VMs para backup separados por espaço."
echo "Exemplo: 1 3 4 (Para fazer backup da primeira, terceira e quarta)"
read -p "Seleção: " selection

# ----------------------------------------
# 4. EXECUÇÃO DO BACKUP (O LOOP MÁGICO)
# ----------------------------------------
echo ""
echo "[4/4] Iniciando Processo de Backup em Lote..."
echo "Aviso: Não feche esta janela."

for id in $selection; do
    # Pega o UUID correspondente à linha escolhida
    UUID=$(sed -n "${id}p" /tmp/uuid_list)
    
    if [ -z "$UUID" ]; then
        echo "ID $id inválido, pulando..."
        continue
    fi

    VM_NAME=$(xe vm-list uuid=$UUID params=name-label --minimal)
    STATE=$(xe vm-list uuid=$UUID params=power-state --minimal)
    FILE_NAME="${MOUNT_POINT}/${VM_NAME// /_}_${DATE_NOW}.xva"

    echo ""
    echo ">>> Processando: $VM_NAME (Estado: $STATE)"
    echo "    UUID: $UUID"

    START_TIME=$(date +%s)

    if [ "$STATE" == "halted" ]; then
        # MODO DESLIGADO (Direto e Rápido)
        echo "    Modo: Exportação Direta (VM Desligada)"
        xe vm-export vm=$UUID filename="$FILE_NAME"
    else
        # MODO LIGADO (Snapshot -> Export -> Delete)
        echo "    Modo: Snapshot a Quente (VM Ligada)"
        echo "    1. Criando Snapshot temporário..."
        # Cria snapshot e captura o UUID dele
        SNAP_UUID=$(xe vm-snapshot uuid=$UUID new-name-label="BACKUP_TEMP_${VM_NAME}")
        
        echo "    2. Exportando Snapshot para USB..."
        xe vm-export snapshot-uuid=$SNAP_UUID filename="$FILE_NAME"
        
        echo "    3. Removendo Snapshot temporário..."
        xe snapshot-uninstall uuid=$SNAP_UUID force=true
    fi

    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    
    if [ -f "$FILE_NAME" ]; then
        SIZE=$(ls -lh "$FILE_NAME" | awk '{print $5}')
        echo "    [SUCESSO] Backup concluído em ${DURATION}s. Tamanho: $SIZE"
    else
        echo "    [ERRO] O arquivo não foi gerado."
    fi
done

echo ""
echo "=========================================="
echo "TODAS AS TAREFAS CONCLUÍDAS."
echo "Desmontando USB..."
umount $MOUNT_POINT
echo "Pode remover o disco com segurança."