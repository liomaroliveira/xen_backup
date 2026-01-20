# Ferramentas de Gerenciamento XenServer para USB

Este repositório contém dois scripts essenciais para administração, backup e documentação de ambientes Citrix XenServer legados, com suporte a exportação direta para USB.

## Scripts Disponíveis

1.  **`wizard_backup.sh` (v6.0)**: Realiza backup completo (arquivo `.xva`) das VMs.
2.  **`wizard_audit.sh` (v1.0)**: Extrai 100% das informações técnicas e metadados de cada VM para arquivos de texto.

---

## 1. Wizard de Backup (`wizard_backup.sh`)

Script automatizado para realizar backup de Máquinas Virtuais (VMs) diretamente para um HD Externo USB.

### Funcionalidades
- **Hot Backup:** Realiza backup de VMs ligadas (Running) usando estratégia de Clone Temporário.
- **Wizard Interativo:** Guia passo a passo para montagem e formatação.
- **Logs Duplos:** Salva logs no servidor e no HD externo.

### Como Usar
1.  Conecte o HD Externo.
2.  Execute:
    
    ./wizard_backup.sh

3.  Siga as instruções na tela para selecionar o disco e as VMs.

---

## 2. Wizard de Auditoria (`wizard_audit.sh`)

Script focado em documentação. Ele varre todas as VMs do servidor e gera um relatório técnico exaustivo ("dump" de configurações) para cada uma.

### O que ele extrai?
Para cada VM, ele cria um arquivo `.txt` contendo:
- **Resumo Geral:** Nome, descrição, vCPUs, RAM.
- **vm-param-list:** A lista completa de parâmetros internos do Xen (BIOS strings, platform settings, PV-args).
- **Discos (VBDs/VDIs):** Detalhes técnicos de cada disco virtual, incluindo UUIDs, flags de boot e local físico.
- **Rede (VIFs):** Endereços MAC, redes conectadas, limites de banda e QoS.
- **Snapshots:** Lista de snapshots vinculados àquela VM.

### Como Usar
1.  Conecte o HD Externo.
2.  Execute:
    
    ./wizard_audit.sh

3.  O script criará uma pasta datada (ex: `AUDITORIA_2026-01-20_18-00`) no HD externo contendo um arquivo por VM.

---

## Detalhes Técnicos e Agendamento

### Montagem de Disco
Ambos os scripts utilizam o diretório `/mnt` como ponto de montagem temporário:
- Backup: `/mnt/usb_backup_wizard`
- Auditoria: `/mnt/usb_audit_wizard`

### Automação no Crontab
Os scripts padrão são interativos. Para agendar no `cron`, você deve criar cópias removendo os comandos `read -p` e definindo as variáveis estáticas no início do arquivo.

**Exemplo de adaptação para Cron:**

    # Defina isso no topo do script modificado
    USB_DEVICE="/dev/sdb1"
    MOUNT_POINT="/mnt/usb_backup_wizard"
    # Remova as partes de detecção automática e perguntas

**Linha do Crontab (Exemplo para rodar todo Domingo às 03:00):**

    0 3 * * 0 /root/scripts/auto_audit.sh >> /var/log/xen_audit.log 2>&1

### Estrutura de Logs
Os logs de execução são salvos automaticamente na raiz do diretório criado no USB e também ficam temporariamente em `/tmp/` durante a execução.

- Formato do Log de Backup: `backup_log_DATA.txt`
- Formato do Log de Auditoria: `audit_log_DATA.txt`