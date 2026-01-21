# Ferramentas de Gerenciamento XenServer para USB

Este repositório contém scripts robustos para administração, backup e documentação de ambientes Citrix XenServer legados, com foco em resiliência e exportação direta para discos USB.

## Scripts Disponíveis

1.  **`wizard_backup.sh` (v12.0)**: Realiza backup completo (`.xva`) das VMs. Inclui monitoramento em tempo real, auto-recuperação de falhas e gestão inteligente de espaço.
2.  **`wizard_audit.sh` (v2.0)**: Extrai 100% das informações técnicas (Host + VMs) para arquivos de texto.

---

## 1. Wizard de Backup (`wizard_backup.sh`)

Script automatizado para backup de VMs diretamente para HD Externo. Projetado para lidar com falhas de storage, interrupções (Ctrl+C) e tarefas travadas.

### Funcionalidades Principais
-   **Auto-Healing (Auto-Cura):** Detecta e remove resíduos de backups falhos (`BACKUP_TEMP_VM`) automaticamente ao iniciar.
-   **Safe Destroy:** Utiliza método seguro de limpeza que evita o aviso crítico de "Shared Disk", garantindo que o disco original nunca seja tocado.
-   **Modo Híbrido Inteligente (Smart Size Logic):**
    -   **Cálculo Dinâmico:** O script calcula se há espaço suficiente para o snapshot baseado no tamanho da VM (Exige 25% do tamanho da VM livre no Storage).
    -   **Previsão de Erro:** Se uma VM de 400GB tiver apenas 80GB livres no storage, o script marcará como `REQ. DESLIGAR` na listagem, evitando que você perca tempo tentando um snapshot que falhará.
    -   **Fallback:** Se o espaço for insuficiente, ele oferece desligar a VM automaticamente.

### Como Usar
1.  Conecte o HD Externo.
2.  Inicie uma sessão `screen` (recomendado):
    
    screen -S backup

3.  Execute o script:
    
    ./wizard_backup.sh

4.  **Fluxo do Wizard:**
    -   **Auto-Check:** Se houver lixo de execução anterior, ele pedirá para limpar.
    -   **Montagem:** Selecione o disco. O script desmonta automaticamente se o disco estiver "busy".
    -   **Seleção:** Uma tabela exibirá a saúde de cada VM.
        -   *Status "REQ. DESLIGAR":* Significa que o storage está muito cheio para snapshot.
    -   **Execução:** Acompanhe o progresso. Se um snapshot falhar, o script perguntará se você deseja tentar o método de desligamento.

---

## 2. Wizard de Auditoria (`wizard_audit.sh`)

Script de documentação técnica profunda. Gera um "Raio-X" do servidor e das máquinas virtuais.

### O que ele extrai?
Cria uma pasta datada (ex: `AUDITORIA_2026-01-21`) contendo:
-   **Dados do Host Físico:** CPU, Versão, Patches instalados, Placas de Rede (PIFs).
-   **Dados das VMs:** Parâmetros de boot, BIOS strings, UUIDs.
-   **Discos e Rede:** Detalhes de VBDs (Discos virtuais) e VIFs (Interfaces virtuais, MACs).

### Como Usar
1.  Execute:
    
    ./wizard_audit.sh

2.  Ao final, você pode escolher **manter o disco montado** para conferir os arquivos antes de remover.

---

## Detalhes Técnicos

### Estratégia de Backup (Hot vs Cold)
O script decide dinamicamente a melhor estratégia:

1.  **VMs Desligadas (Cold):** Usa `xe vm-export` direto. Seguro e não consome espaço extra no storage.
2.  **VMs Ligadas (Hot - Snapshot):**
    -   Cria Snapshot -> Clona para VM Temporária -> Exporta -> Destrói.
    -   *Nota:* Requer espaço livre no Storage Repository (SR) igual ao tamanho das mudanças no disco.
3.  **Fallback (Recuperação):** Se o Snapshot falhar (Erro `SR_BACKEND_FAILURE`), o script captura o erro e permite alternar para o modo Cold (Desligar/Ligar) na mesma hora.

### Correção de "Shared Disk Warning"
Nas versões antigas, o comando `vm-uninstall` gerava alertas assustadores sobre discos compartilhados. A versão V11+ utiliza `xe vm-destroy` para remover apenas o registro da VM temporária e `xe snapshot-uninstall` para limpar os dados, eliminando qualquer risco aos discos originais.

### Logs e Auditoria
-   Todos os passos são registrados em log duplo (gravado no servidor em `/tmp` e no USB).
-   Se o script for interrompido (`Ctrl+C`), ele intercepta o sinal e tenta desmontar o disco com segurança.

---

## Proteção e Agendamento

### Proteção contra Quedas (Screen)
Como backups podem demorar horas, sempre execute dentro do `screen`:

    yum install screen
    screen -S backup_session
    ./wizard_backup.sh

-   **Sair e deixar rodando:** Pressione `Ctrl+A`, depois `D`.
-   **Voltar:** `screen -r backup_session`

### Automação (Cron)
Para agendar, crie uma cópia do script (`auto_backup.sh`), remova as perguntas interativas (`read -p`) e defina as variáveis no topo:

    USB_DEVICE="/dev/sdb1"
    SELECTION_UUIDS="uuid1 uuid2"
    AUTO_UNMOUNT="S"