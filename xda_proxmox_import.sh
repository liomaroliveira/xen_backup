#!/bin/bash
# ==========================================
# IMPORTADOR XENSERVER (.XVA) PARA PROXMOX
# ==========================================

# Configurações Padrão
STORAGE_DESTINO="local-lvm"  # Onde o disco será salvo no Proxmox (local-lvm, local-zfs, etc)
TEMP_DIR="/var/tmp/xen_import"

clear
echo "=========================================="
echo "   MIGRAR XVA -> PROXMOX "
echo "=========================================="

# 1. DETECTAR E MONTAR USB
echo "[1/5] Configurando USB no Proxmox..."
mkdir -p /mnt/usb_import

# Tenta achar o disco USB (geralmente sdb ou sdc)
# Lista discos que NÃO estão montados na raiz
USB_CANDIDATE=$(lsblk -rn -o NAME,TRAN,MOUNTPOINT | grep "usb" | awk '{print $1}' | head -n 1)

if [ -z "$USB_CANDIDATE" ]; then
    echo "ERRO: Nenhum disco USB detectado automaticamente."
    echo "Liste manualmente com 'lsblk' e monte em /mnt/usb_import"
    echo "Exemplo: mount /dev/sdb1 /mnt/usb_import"
    exit 1
else
    USB_DEV="/dev/$USB_CANDIDATE"
    # Se tiver partição (ex sdb1), usa ela
    if [ -b "${USB_DEV}1" ]; then USB_DEV="${USB_DEV}1"; fi
    
    echo ">> USB detectado em: $USB_DEV"
    if ! mountpoint -q /mnt/usb_import; then
        mount $USB_DEV /mnt/usb_import
    fi
fi

# 2. LISTAR ARQUIVOS XVA
echo ""
echo "[2/5] Arquivos de Backup Encontrados:"
mapfile -t FILES < <(ls /mnt/usb_import/*.xva 2>/dev/null)

if [ ${#FILES[@]} -eq 0 ]; then
    echo "ERRO: Nenhum arquivo .xva encontrado em /mnt/usb_import"
    exit 1
fi

i=1
for f in "${FILES[@]}"; do
    filename=$(basename "$f")
    size=$(ls -lh "$f" | awk '{print $5}')
    echo "  [$i] $filename ($size)"
    ((i++))
done

echo ""
read -p "Escolha o número do arquivo para importar: " file_opt
SELECTED_FILE="${FILES[$((file_opt-1))]}"

if [ -z "$SELECTED_FILE" ]; then echo "Opção inválida"; exit 1; fi

# 3. DADOS DA NOVA VM
echo ""
echo "[3/5] Configuração da Nova VM"
read -p "Digite o ID da nova VM (ex: 100, 101): " VMID
read -p "Digite um nome para a VM (sem espaços): " VMNAME
read -p "Quantos GB de RAM? (ex: 4096): " MEMORY
read -p "Quantos Cores de CPU? (ex: 2): " CORES

echo ">> Criando VM esqueleto..."
qm create $VMID --name "$VMNAME" --memory $MEMORY --cores $CORES --net0 virtio,bridge=vmbr0 --ostype l26
echo ">> VM $VMID criada."

# 4. CONVERSÃO (A MÁGICA)
echo ""
echo "[4/5] Extraindo e Convertendo (Isso vai demorar)..."
echo ">> Extraindo XVA (pode levar minutos)..."
rm -rf $TEMP_DIR
mkdir -p $TEMP_DIR
tar -xf "$SELECTED_FILE" -C $TEMP_DIR

# Encontra a pasta do disco (Geralmente Ref:X)
# O XVA pode ter múltiplos discos. Vamos pegar o maior (geralmente o SO)
# Se suas VMs tem 2 discos, precisaria adaptar, mas vamos focar no principal.
DISK_REF=$(du -s $TEMP_DIR/Ref* | sort -nr | head -n 1 | awk '{print $2}')

if [ -z "$DISK_REF" ]; then
    echo "ERRO: Não encontrei a pasta de disco dentro do XVA."
    exit 1
fi

echo ">> Convertendo blocos Xen para RAW (usando xva-img)..."
/usr/local/bin/xva-img -p disk-export "$DISK_REF/" > $TEMP_DIR/disk.raw

# 5. IMPORTAÇÃO
echo ""
echo "[5/5] Importando para o Proxmox Storage ($STORAGE_DESTINO)..."
qm importdisk $VMID $TEMP_DIR/disk.raw $STORAGE_DESTINO --format raw

echo ">> Anexando disco à VM..."
# Pega o nome do disco importado (ex: vm-100-disk-0)
IMPORTED_DISK=$(qm config $VMID | grep unused | awk '{print $2}')
# Anexa como SCSI (melhor performance)
qm set $VMID --scsihw virtio-scsi-pci --scsi0 $IMPORTED_DISK
# Define ordem de boot
qm set $VMID --boot c --bootdisk scsi0

# Limpeza
echo ">> Limpando arquivos temporários..."
rm -rf $TEMP_DIR
rm $TEMP_DIR/disk.raw 2>/dev/null

echo ""
echo "=========================================="
echo "SUCESSO! A VM $VMID ($VMNAME) foi criada."
echo "IMPORTANTE: Antes de ligar, verifique:"
echo "1. Se a VM era Linux: Deve subir normal."
echo "2. Se era Windows: Pode precisar mudar o disco de SCSI para IDE/SATA nas opções do Proxmox se der tela azul."
echo "=========================================="