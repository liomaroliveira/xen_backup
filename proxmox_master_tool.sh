#!/bin/bash
# ============================================================
# PROXMOX MASTER TOOL - EXPORT, AUDIT & MANAGE
# Versão: 1.1 (Fix Vzdump Notes Error)
# Funcionalidades: Backup (vzdump), Auditoria Host/VM, Snapshots
# ============================================================

# --- CONFIGURAÇÕES ---
LOG_FILE="/var/log/pve_master_tool_$(date +%Y%m%d_%H%M).log"
DATE_NOW=$(date +%Y-%m-%d_%H-%M)
HOSTNAME=$(hostname)

# --- CORES ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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
    echo "[$(date +'%H:%M:%S')] [$level] $msg" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"
    sync "$LOG_FILE"
}

# Trap para Cancelamento Seguro
cleanup_on_cancel() {
    echo ""
    log "!!! INTERRUPÇÃO DETECTADA !!!" "ERROR"
    log "Parando processos vzdump/tar..." "WARN"
    pkill -P $$ 2>/dev/null
    exit 1
}
trap cleanup_on_cancel INT TERM

# --- 1. DETECÇÃO DE ARMAZENAMENTO (USB/LOCAL) ---

detect_storage() {
    echo ""
    log "SELECIONE O DESTINO (Para salvar Backups e Auditoria):"
    
    # Lista USBs
    mapfile -t DISKS < <(lsblk -rn -o NAME,SIZE,TRAN,MOUNTPOINT | grep "usb" | grep -v "sda")
    [ ${#DISKS[@]} -eq 0 ] && mapfile -t DISKS < <(lsblk -rn -o NAME,SIZE,TRAN,MOUNTPOINT | grep "sd" | grep -v "sda")

    echo "  [0] Diretório Local (Digitar caminho manual)"
    
    i=1
    for disk in "${DISKS[@]}"; do
        echo "  [$i] USB: /dev/$disk"
        ((i++))
    done
    
    read -p "Opção: " disk_opt
    
    if [ "$disk_opt" == "0" ]; then
        read -p "Digite o caminho completo (ex: /mnt/pve/backups): " custom_path
        if [ -d "$custom_path" ]; then
            EXPORT_DIR="$custom_path"
        else
            log "Diretório inválido." "ERROR"; exit 1
        fi
    elif [ "$disk_opt" -gt 0 ] && [ "$disk_opt" -le "${#DISKS[@]}" ]; then
        SELECTED_DISK_LINE="${DISKS[$((disk_opt-1))]}"
        SELECTED_DEV="/dev/$(echo $SELECTED_DISK_LINE | awk '{print $1}')"
        EXPORT_DIR="/mnt/pve_export_usb"
        mkdir -p $EXPORT_DIR
        
        CURRENT_MOUNT=$(echo $SELECTED_DISK_LINE | awk '{print $4}')
        if [ -n "$CURRENT_MOUNT" ]; then
            EXPORT_DIR="$CURRENT_MOUNT"
        else
            mount $SELECTED_DEV $EXPORT_DIR
        fi
    else
        log "Opção inválida." "ERROR"; exit 1
    fi
    
    log "Diretório de Exportação: $EXPORT_DIR" "SUCCESS"
}

# --- 2. AUDITORIA COMPLETA (HOST + VMS) ---

run_audit() {
    AUDIT_DIR="$EXPORT_DIR/AUDITORIA_${HOSTNAME}_${DATE_NOW}"
    mkdir -p "$AUDIT_DIR"
    log "Iniciando Auditoria em: $AUDIT_DIR"
    
    # 2.1 Auditoria do Host (Arquivos Vitais para Migração)
    log ">>> Copiando configurações do Host Proxmox..."
    
    # Cria estrutura
    mkdir -p "$AUDIT_DIR/HOST_CONFIGS/etc_network"
    mkdir -p "$AUDIT_DIR/HOST_CONFIGS/etc_pve"
    
    # Rede
    cp /etc/network/interfaces "$AUDIT_DIR/HOST_CONFIGS/etc_network/" 2>/dev/null
    cp /etc/hosts "$AUDIT_DIR/HOST_CONFIGS/" 2>/dev/null
    
    # Storage e Cluster
    cp /etc/pve/storage.cfg "$AUDIT_DIR/HOST_CONFIGS/etc_pve/" 2>/dev/null
    cp /etc/pve/user.cfg "$AUDIT_DIR/HOST_CONFIGS/etc_pve/" 2>/dev/null
    
    # Versões
    pveversion -v > "$AUDIT_DIR/HOST_CONFIGS/pve_version.txt"
    lsblk > "$AUDIT_DIR/HOST_CONFIGS/disk_layout.txt"
    ip addr > "$AUDIT_DIR/HOST_CONFIGS/network_current_state.txt"
    
    # Compacta Host Configs
    tar -czf "$AUDIT_DIR/HOST_BKP_${HOSTNAME}.tar.gz" -C "$AUDIT_DIR/HOST_CONFIGS" .
    rm -rf "$AUDIT_DIR/HOST_CONFIGS"
    
    log "    [OK] Configurações do Host salvas." "SUCCESS"
    
    # 2.2 Auditoria das VMs
    log ">>> Gerando relatórios das VMs..."
    
    mapfile -t VMS < <(qm list | awk 'NR>1 {print $1}')
    
    for vmid in "${VMS[@]}"; do
        vmname=$(qm config $vmid | grep "name:" | awk '{print $2}')
        [ -z "$vmname" ] && vmname="VM_$vmid"
        
        REPORT_FILE="$AUDIT_DIR/VM_${vmid}_${vmname}.txt"
        
        echo "=== RELATÓRIO TÉCNICO: $vmname ($vmid) ===" > "$REPORT_FILE"
        echo "Data: $DATE_NOW" >> "$REPORT_FILE"
        echo "-------------------------------------------" >> "$REPORT_FILE"
        echo "STATUS ATUAL:" >> "$REPORT_FILE"
        qm status $vmid >> "$REPORT_FILE"
        echo "" >> "$REPORT_FILE"
        echo "CONFIGURAÇÃO (qm config):" >> "$REPORT_FILE"
        qm config $vmid >> "$REPORT_FILE"
        echo "" >> "$REPORT_FILE"
        echo "DISCOS VIRTUAIS:" >> "$REPORT_FILE"
        qm config $vmid | grep -E "scsi|sata|ide|virtio" >> "$REPORT_FILE"
        echo "" >> "$REPORT_FILE"
        echo "REDE:" >> "$REPORT_FILE"
        qm config $vmid | grep "net" >> "$REPORT_FILE"
        
        log "    [OK] VM $vmid ($vmname)"
    done
    
    log "Auditoria Concluída." "SUCCESS"
}

# --- 3. EXPORTAÇÃO (BACKUP VZDUMP) ---

run_export() {
    log "--- EXPORTAÇÃO DE VMS (VZDUMP) ---"
    
    # Listar VMs
    qm list
    echo "-------------------------------------"
    echo "Digite os IDs das VMs para exportar (separados por espaço)."
    echo "Ex: 100 102 105 (Ou 'ALL' para todas)"
    read -p "Seleção: " selection
    
    if [ "$selection" == "ALL" ] || [ "$selection" == "all" ]; then
        mapfile -t TARGET_VMS < <(qm list | awk 'NR>1 {print $1}')
    else
        TARGET_VMS=($selection)
    fi
    
    # Configuração do Backup
    echo ""
    echo "Modo de Backup:"
    echo "  [1] Snapshot (A Quente - Padrão)"
    echo "  [2] Suspend (Pausa Rápida)"
    echo "  [3] Stop (Desliga e Liga - Mais Seguro)"
    read -p "Opção [1]: " mode_opt
    case $mode_opt in
        2) BKP_MODE="suspend" ;;
        3) BKP_MODE="stop" ;;
        *) BKP_MODE="snapshot" ;;
    esac
    
    # Execução
    idx=1
    total=${#TARGET_VMS[@]}
    
    for vmid in "${TARGET_VMS[@]}"; do
        vmname=$(qm config $vmid | grep "name:" | awk '{print $2}')
        echo ""
        log ">>> Exportando VM $idx/$total: $vmid ($vmname)" "INFO"
        log "    Modo: $BKP_MODE | Compressão: ZSTD"
        log "    Destino: $EXPORT_DIR"
        
        # FIX V1.1: Removido --notes-template pois causa conflito com --dumpdir (raw path)
        vzdump $vmid --dumpdir "$EXPORT_DIR" --mode $BKP_MODE --compress zstd
        
        if [ $? -eq 0 ]; then
            log "    [SUCESSO] Backup da VM $vmid concluído." "SUCCESS"
        else
            log "    [ERRO] Falha ao exportar VM $vmid." "ERROR"
            read -p "Pressione ENTER para continuar com as próximas..."
        fi
        ((idx++))
    done
}

# --- 4. GERENCIAMENTO DE SNAPSHOTS ---

manage_snapshots() {
    log "--- GERENCIADOR DE SNAPSHOTS ---"
    qm list
    echo "-------------------------------------"
    read -p "Digite o ID da VM alvo: " vmid
    
    if ! qm status $vmid &>/dev/null; then log "VM não encontrada." "ERROR"; return; fi
    
    echo ""
    echo "Snapshots atuais:"
    qm listsnapshot $vmid
    echo "-------------------------------------"
    echo "  [1] CRIAR Snapshot"
    echo "  [2] RESTAURAR (Rollback)"
    echo "  [3] DELETAR Snapshot"
    read -p "Ação: " action
    
    case $action in
        1)
            read -p "Nome do Snapshot (sem espaços): " snap_name
            read -p "Incluir Estado da RAM? (Mais lento, salva estado ligado) [y/N]: " ram_opt
            if [[ "$ram_opt" =~ ^[yY]$ ]]; then
                qm snapshot $vmid "$snap_name" --vmstate 1
            else
                qm snapshot $vmid "$snap_name"
            fi
            log "Snapshot '$snap_name' criado." "SUCCESS"
            ;;
        2)
            read -p "Nome do Snapshot para restaurar: " snap_name
            log "Restaurando..."
            qm rollback $vmid "$snap_name"
            log "Rollback concluído." "SUCCESS"
            ;;
        3)
            read -p "Nome do Snapshot para APAGAR: " snap_name
            log "Apagando..."
            qm delsnapshot $vmid "$snap_name"
            log "Snapshot apagado." "SUCCESS"
            ;;
        *) log "Opção inválida." "ERROR" ;;
    esac
}

# --- MENU PRINCIPAL ---

show_menu() {
    clear
    log "==============================================="
    log "   PROXMOX MASTER TOOL (HOST: $HOSTNAME)"
    log "==============================================="
    echo "  [1] EXPORTAR VMs (Backup Completo para USB/Local)"
    echo "  [2] AUDITORIA COMPLETA (Host + Configs VMs)"
    echo "  [3] GERENCIAR SNAPSHOTS"
    echo "  [4] SAIR"
    echo ""
    read -p "Escolha uma opção: " main_opt
    
    case $main_opt in
        1)
            detect_storage
            run_export
            ;;
        2)
            detect_storage
            run_audit
            ;;
        3)
            manage_snapshots
            ;;
        4)
            exit 0
            ;;
        *)
            log "Opção inválida." "ERROR"
            sleep 1
            show_menu
            ;;
    esac
    
    echo ""
    read -p "Pressione ENTER para voltar ao menu..."
    show_menu
}

# --- INÍCIO ---
# Verifica se é root
if [ "$EUID" -ne 0 ]; then 
    echo "Por favor, execute como root."
    exit 1
fi

show_menu