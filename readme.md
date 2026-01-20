# Wizard de Backup XenServer para USB

Script automatizado para realizar backup de Máquinas Virtuais (VMs) do Citrix XenServer diretamente para um disco rígido externo USB.

## Funcionalidades

- **Detecção Automática:** Identifica HDs externos USB conectados ao servidor.
- **Wizard Interativo:** Guia passo a passo para montagem, formatação (opcional) e seleção de VMs.
- **Suporte a "Hot Backup":** Realiza backup de VMs ligadas (Running) sem desligamento, utilizando uma estratégia de Snapshot + Clone temporário.
- **Logs Duplos:** Gera relatórios de execução detalhados salvos tanto no diretório do script quanto na raiz do HD externo para conferência posterior.
- **Compatibilidade:** Funciona em versões legadas do XenServer (6.x, 7.x) que possuem limitações na exportação direta de snapshots.

## Pré-requisitos

1. Acesso SSH ao servidor XenServer (usuário root).
2. HD Externo conectado a uma porta USB do servidor.
3. Permissão de execução no script.

## Instalação

1. Salve o script no servidor (ex: `/root/scripts/wizard_backup.sh`).
2. Dê permissão de execução:
    
    chmod +x wizard_backup.sh

## Como Usar

1. Conecte o HD Externo no servidor.
2. Execute o script:

    ./wizard_backup.sh

3. **Passo 1:** O script listará os discos. Selecione o número correspondente ao seu HD Externo (identificado como "usb" ou pela marca).
4. **Passo 2:** Escolha se deseja formatar o disco.
    - Recomendamos formatar em **EXT4** para garantir velocidade e suporte a arquivos maiores que 4GB.
    - Se o disco já foi formatado anteriormente por este script, basta escolher "Não".
5. **Passo 3:** O script listará todas as VMs com detalhes (CPU, RAM, Uso de Disco). Digite os IDs das VMs que deseja salvar, separados por espaço (ex: `1 3 4`).
6. **Passo 4:** Aguarde o processo. O script exibirá o progresso, criará os arquivos `.xva` e desmontará o disco automaticamente ao final.

## Logs

Ao final de cada execução, um arquivo de log (ex: `backup_log_2026-01-20_17-30.txt`) é gerado contendo:
- Horário de início e fim.
- Status de cada VM (Sucesso/Erro).
- Tamanho final do arquivo gerado.

O log é salvo automaticamente em dois locais:
1. No diretório onde o script foi executado.
2. Na raiz do HD Externo (pasta `/mnt/usb_backup_wizard/`).

## Explicação Técnica dos Comandos

Para fins de documentação e manutenção, abaixo está a explicação das etapas críticas do script:

### 1. Gerenciamento de Disco
- `lsblk`: Utilizado para diferenciar discos de sistema (`sda`) de discos removíveis.
- `mkfs.ext4`: Formata o disco no sistema de arquivos nativo do Linux. Essencial pois sistemas NTFS/FAT podem corromper arquivos de backup grandes ou ter desempenho de escrita muito lento no XenServer.

### 2. Estratégia de Backup (Hot Backup)
O XenServer possui limitações para exportar VMs ligadas. Para contornar isso com segurança, o script utiliza o seguinte fluxo na Versão 6.0:

1. **Snapshot (`xe vm-snapshot`):** Cria um ponto de restauração instantâneo do disco.
2. **Clone (`xe vm-clone`):** Transforma esse snapshot em uma VM temporária parada. Isso é necessário porque o comando `vm-export` padrão muitas vezes falha ao tentar exportar um snapshot diretamente em versões antigas.
3. **Exportação (`xe vm-export`):** Exporta a VM clonada para o arquivo `.xva` no USB.
4. **Limpeza (`xe vm-uninstall`):** Remove a VM clonada e o snapshot original para liberar espaço no Storage Repository (SR).

## Automação (Crontab)

Este script (`wizard_backup.sh`) é **interativo** e não deve ser colocado diretamente no Cron, pois ele pausará aguardando a seleção do usuário.

Para agendar backups automáticos, crie uma cópia do script (ex: `auto_backup.sh`) e faça as seguintes alterações:

1. Remova as linhas com `read -p` (perguntas).
2. Defina as variáveis fixas no início do arquivo:

    # Exemplo de configuração fixa para Cron
    USB_DEVICE="/dev/sdb1"
    MOUNT_POINT="/mnt/usb_backup_wizard"
    # Liste os UUIDs das VMs que deseja salvar (separados por espaço)
    SELECTION_UUIDS="uuid-da-vm-1 uuid-da-vm-2"

3. Substitua o loop `for vm_id in $selection` para iterar sobre a variável `$SELECTION_UUIDS`.

### Exemplo de agendamento (Crontab)
Para rodar toda sexta-feira às 23:00:

    0 23 * * 5 /root/scripts/auto_backup.sh >> /var/log/xen_backup_cron.log 2>&1