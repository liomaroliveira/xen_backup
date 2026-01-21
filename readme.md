# Ferramentas de Migração e Gerenciamento: XenServer -> Proxmox

Este repositório contém uma suíte completa de scripts para administrar, realizar backup, auditar e **migrar** ambientes Citrix XenServer legados para Proxmox VE, com foco em segurança de dados e integridade de rede.

## Scripts Disponíveis

1.  **`wizard_backup.sh` (v13.0)**: Realiza backup seguro de VMs (`.xva`) para USB. Possui inteligência para lidar com storage cheio e correções automáticas.
2.  **`wizard_audit.sh` (v2.0)**: Extrai 100% das configurações técnicas (Rede, MACs, Hardware) para facilitar a recriação da VM.
3.  **`xva_proxmox_import.sh` (v1.1)**: Automatiza a importação no Proxmox, convertendo discos e clonando as configurações de rede originais.

---

## 1. Wizard de Backup (`wizard_backup.sh`)

Script de backup resiliente para XenServer. Projetado para ambientes críticos e storages com pouco espaço.

### Funcionalidades Principais
-   **Smart Size Logic:** Calcula dinamicamente se o storage tem espaço para um snapshot seguro (exige 25% do tamanho da VM livre). Se não tiver, sugere o modo *Shutdown* automaticamente.
-   **Auto-Healing (Auto-Cura):** Detecta resíduos de falhas anteriores e limpa snapshots órfãos ao iniciar.
-   **Safe Destroy:** Remove VMs temporárias sem gerar alertas de "Shared Disk", garantindo zero risco aos dados originais.
-   **Anti-Freeze:** Detecta se a Toolstack (XAPI) travou e reinicia o serviço automaticamente.
-   **Monitoramento em Tempo Real:** Exibe o progresso do tamanho do arquivo durante a exportação.

### Como Usar (No XenServer)
1.  Conecte o HD Externo.
2.  Inicie uma sessão segura (veja seção "Proteção contra Quedas").
3.  Execute:
    
    ./wizard_backup.sh

---

## 2. Wizard de Auditoria (`wizard_audit.sh`)

Gera um "Raio-X" completo do ambiente XenServer. Essencial para garantir que a VM migrada terá as mesmas configurações.

### O que ele extrai?
Cria arquivos de texto contendo:
-   **Hardware:** Quantidade exata de vCPUs, RAM (em bytes) e ordem de boot.
-   **Identidade de Rede:** Endereços MAC de todas as interfaces virtuais (VIFs) e suas respectivas VLANs/Networks.
-   **Storage:** Mapeamento dos discos virtuais (VBDs).

### Como Usar (No XenServer)
    ./wizard_audit.sh

*Os arquivos serão salvos no HD Externo, na pasta `AUDITORIA_DATA`.*

---

## 3. Importador Proxmox (`xva_proxmox_import.sh`)

Script de automação para rodar no servidor de destino (**Proxmox**). Ele lê o backup `.xva` e os logs de auditoria para recriar a VM com fidelidade total.

### Funcionalidades Exclusivas
-   **Clonagem de Rede (Smart Network):** Lê os logs de auditoria para aplicar o **mesmo MAC Address** e a **mesma VLAN Tag** na nova VM. O roteador/switch nem perceberá a troca de hardware.
-   **Conversão RAW:** Converte o arquivo XVA proprietário para `.raw` (bit-a-bit), garantindo máxima integridade e compatibilidade com ZFS/LVM-Thin.
-   **Gestão de Dependências:** Instala e compila automaticamente as ferramentas necessárias (`xva-img`, `libxxhash-dev`, etc) se não estiverem presentes.
-   **Logs Duplos:** Salva o relatório da importação tanto no Proxmox quanto no HD USB.

### Como Usar (No Proxmox)
1.  Conecte o HD Externo (contendo os backups e a pasta de auditoria) no Proxmox.
2.  Execute:
    
    ./xva_proxmox_import.sh

3.  **O Wizard irá:**
    -   Montar o USB.
    -   Listar os arquivos `.xva`.
    -   Detectar automaticamente CPU, RAM e MACs originais.
    -   Converter e importar o disco para o Storage local (ex: `local-zfs`).

---

## Detalhes Técnicos e Segurança

### Estratégia de Backup (Híbrida)
O script `wizard_backup.sh` decide a melhor rota:
1.  **Hot Backup (Snapshot):** Se houver espaço (>25% do disco da VM), faz snapshot e exporta sem desligar.
2.  **Cold Backup (Shutdown):** Se o storage estiver cheio, oferece desligar a VM temporariamente, exportar e religar. Isso contorna o erro `SR_BACKEND_FAILURE_44`.

### Estratégia de Importação
Para garantir performance e não lotar o disco principal do Proxmox:
-   O script permite escolher onde realizar a conversão temporária:
    -   **[1] Local:** Mais rápido (SSD), mas exige espaço livre temporário igual ao tamanho da VM.
    -   **[2] USB:** Mais lento, mas economiza espaço no servidor Proxmox.

---

## Proteção contra Quedas (Essencial)

Como os processos de backup e importação podem levar horas, **sempre** execute os scripts dentro de um multiplexador de terminal. Isso garante que, se sua conexão SSH cair ou você fechar a janela, o processo continue rodando no servidor.

Escolha a ferramenta de sua preferência:

### Opção A: Screen (Padrão XenServer/CentOS)
1.  **Instalar:**
    `apt install screen` (Debian/Proxmox) ou `yum install screen` (CentOS/Xen).
2.  **Criar sessão:**
    `screen -S migracao`
3.  **Sair e deixar rodando (Detach):**
    Pressione `Ctrl+A`, solte e pressione `D`.
4.  **Voltar para a sessão (Reattach):**
    `screen -r migracao`

### Opção B: Tmux (Padrão Proxmox/Debian Moderno)
1.  **Instalar:**
    `apt install tmux`
2.  **Criar sessão:**
    `tmux new -s migracao`
3.  **Sair e deixar rodando (Detach):**
    Pressione `Ctrl+B`, solte e pressione `D`.
4.  **Voltar para a sessão (Attach):**
    `tmux attach -t migracao`

---

## Logs
Todos os scripts geram logs detalhados em `/tmp/` (ou `/var/log/`) e copiam uma versão final para a raiz do HD Externo para conferência posterior.