# windows-maintenance.ps1

Script de manutenção profunda e otimização de sistemas Windows, com 28 etapas automatizadas cobrindo desde limpeza de cache até tuning de rede e registro.

## O que faz

| Etapa | Ação |
|---|---|
| Diagnóstico | TOP 10 processos por CPU e memória, espaço em disco, programas na inicialização |
| Plano de energia | Ativa Alto Desempenho, desativa hibernação e Fast Startup |
| Integridade do sistema | DISM (CheckHealth → ScanHealth → RestoreHealth) + SFC /scannow |
| Saúde do disco | Verificação SMART via CIM |
| Performance | Ajuste de prioridade de processo, efeitos visuais, WaitToKillServiceTimeout |
| Limpeza de temporários | `%TEMP%`, `%windir%\Temp`, Prefetch |
| Componentes DISM | `startcomponentcleanup /resetbase` |
| Disco | TRIM (SSD) ou Defrag (HDD) via `Optimize-Volume` |
| Caches | Miniaturas, ícones, fontes, IE/Edge legado, Chrome, Edge Chromium (todos os perfis) |
| Lixeira | Esvaziamento + configuração de exclusão imediata |
| Logs de eventos | Limpeza de todos os canais via `wevtutil` |
| CleanMgr | Execução automatizada via StateFlags |
| Downloads | Remove arquivos com mais de 30 dias |
| Serviços críticos | Verifica e reinicia Winmgmt, RpcSs, EventLog, W32Time |
| Inicialização | Remove delay do Explorer, desativa Fast Startup híbrido |
| Telemetria | Desativa DiagTrack, dmwappushservice, WerSvc, PcaSvc e política de coleta |
| Apps em segundo plano | Desativa GlobalUserDisabled + BackgroundAppGlobalToggle |
| SysMain | Desativa em HDD, mantém em SSD (detecção automática) |
| Windows Update | Limpa cache de downloads e Delivery Optimization |
| DNS e rede | Flush DNS, TCP auto-tuning, desativa EEE e wake-on-LAN nos adaptadores ativos |
| .NET NGEN | Dispara otimização de assemblies via tarefas agendadas |
| Windows Search | Reconstrói índice de pesquisa |
| Pagefile | Garante gerenciamento automático pelo sistema |
| Auditoria | Lista tarefas agendadas de terceiros ativas |
| CHKDSK + reboot | Agenda verificação de disco e reinicia em 15 segundos |

## Requisitos

- Windows 10 / 11
- PowerShell 5.1+
- Execução como **Administrador**

## Uso

```powershell
# Abra o PowerShell como Administrador
.\windows-maintenance.ps1
```

O sistema será reiniciado automaticamente ao final. Salve todo trabalho antes de executar.

## Notas

- O script se auto-deleta após a execução via processo `cmd` externo
- Todas as ações são logadas no terminal com indicação de etapa `[N/28]`
- SysMain é desativado apenas em HDD — em SSD permanece ativo conforme recomendação da Microsoft
