# cherwell-automation

Kit de automações em PowerShell para o Cherwell Service Management (CSM): relatório semanal de chamados, respostas padrão, checagem de host e exportação via REST API. Os scripts são chamados por One-Step Actions (ação **Run a Program**) ou rodam sozinhos a partir de um CSV exportado.

## O que faz

| Script | Função |
|---|---|
| [`cherwell-bridge-test.ps1`](cherwell-bridge-test.ps1) | Grava log com o ID do chamado — prova que o "Run a Program" consegue chamar scripts externos |
| [`cherwell-host-check.ps1`](cherwell-host-check.ps1) | Ping ou teste de porta TCP; devolve o resultado como código de saída para a One-Step decidir a próxima ação |
| [`cherwell-reply-template.ps1`](cherwell-reply-template.ps1) | Monta resposta padrão (encerramento, aguardando usuário, visita técnica, escalonamento) e copia para a área de transferência |
| [`cherwell-weekly-report.ps1`](cherwell-weekly-report.ps1) | Lê o CSV de uma busca salva, calcula os indicadores da semana, gera HTML e monta o e-mail no Outlook |
| [`cherwell-api-export.ps1`](cherwell-api-export.ps1) | Login OAuth2, busca paginada na REST API e exportação para CSV no formato do relatório |

Indicadores do relatório semanal:

1. Abertos e fechados no período, e o saldo entre eles
2. Backlog atual e backlog envelhecido (aberto há mais de N dias)
3. Tempo de resolução — média e mediana, em horas
4. Quebras por categoria, técnico e status
5. CSV anexo com o backlog envelhecido completo

## Requisitos

- Windows PowerShell 5.1+ ou PowerShell 7+
- Outlook instalado — só para o envio de e-mail
- Client ID da REST API (CSM Administrator → Security → Edit REST API client settings) — só para `cherwell-api-export.ps1`

## Uso

Teste com os dados de exemplo (60 chamados fictícios):

```powershell
.\cherwell-weekly-report.ps1 -InputPath .\exemplos\incidentes_exemplo.csv -ReferenceDate 2026-11-23
.\cherwell-reply-template.ps1 -TemplateName encerramento -IncidentId "INC-101234" -CustomerName "Maria Silva" -Category "Impressora"
.\cherwell-host-check.ps1 -HostName "localhost"; $LASTEXITCODE
.\cherwell-bridge-test.ps1 -IncidentId "INC-TESTE" -LogPath ".\saida\ponte.log"
```

Resultado esperado do relatório com os dados de exemplo:

| Indicador | Valor |
|---|---|
| Abertos no período | 13 |
| Fechados no período | 5 |
| Saldo | -8 |
| Backlog atual | 28 |
| Backlog > 7 dias | 18 |
| Tempo médio de resolução (h) | 77,5 |
| Tempo mediano de resolução (h) | 84,8 |

O HTML fica em `saida\relatorio_semanal_2026-11-23.html`.

Chamada pelo Cherwell (One-Step → Run a Program):

```
Programa:   powershell.exe
Argumentos: -NoProfile -ExecutionPolicy Bypass -File "C:\scripts\cherwell-host-check.ps1" -HostName "<token do host>"
```

Marque **Store Exit Code from Program** e use o código na condição da próxima ação.

Export feito pela interface do Cherwell (colunas com nome de exibição):

```powershell
.\cherwell-weekly-report.ps1 -InputPath "C:\scripts\exports" `
    -IdColumn "Incident ID" -OwnerColumn "Owned By" `
    -CreatedColumn "Created Date Time" -ClosedColumn "Closed Date Time" `
    -DateCulture "pt-BR"
```

Se faltar alguma coluna, o script lista as que existem no arquivo. Para o e-mail, `-SendEmail -To "gestor@empresa.com.br"` abre a mensagem para revisão; `-SendNow` envia direto.

Via REST API:

```powershell
.\cherwell-api-export.ps1 -SaveCredential
.\cherwell-api-export.ps1 -ServerUrl "https://cherwell.empresa.local" -ClientId "<client id>" -OutputCsv ".\exports\api.csv"
.\cherwell-weekly-report.ps1 -InputPath ".\exports\api.csv" -DateCulture "en-US"
```

## Códigos de saída

| Código | bridge-test / reply-template | host-check | weekly-report / api-export |
|---|---|---|---|
| 0 | OK | Online | OK |
| 1 | — | Offline | Sem registros |
| 2 | — | Erro (DNS) | Erro |

## Notas

- Os `.ps1` estão em **UTF-8 com BOM** — sem o BOM, o Windows PowerShell 5.1 quebra os acentos dos textos gerados
- O e-mail abre para revisão por padrão; `-SendNow` só depois de validar o conteúdo
- Em Scheduled Items a One-Step roda no servidor, então o "Run a Program" não enxerga scripts da máquina local
- Cada login na REST API consome uma licença do CSM; o script faz logout no final
- A credencial da API é salva com `Export-Clixml` (criptografia DPAPI só no Windows, vinculada ao usuário)
- Os dados de `exemplos/` são fictícios
