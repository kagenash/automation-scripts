<#
.SYNOPSIS
    Lê o CSV exportado de uma busca salva do Cherwell, calcula os indicadores da semana,
    gera um relatório em HTML e (opcional) monta o e-mail no Outlook.

.DESCRIPTION
    ATENÇÃO: script genérico, APENAS PARA TESTE E ESTUDO. Revise e adapte antes de qualquer uso em produção.

    Período analisado: os últimos N dias completos, sem contar o dia de referência.
    Exemplo: rodando na segunda 23/11 com -Days 7, o período vai de 16/11 00:00 até 22/11 23:59.

    Indicadores:
        - Abertos e fechados no período
        - Backlog atual (tudo o que não está em status de fechado)
        - Backlog envelhecido (aberto há mais de N dias)
        - Tempo de resolução (média e mediana, em horas) dos fechados no período
        - Tabelas por status, categoria e técnico

    Códigos de saída:
        0 = relatório gerado
        1 = CSV sem registros (gera só um aviso)
        2 = erro (arquivo não encontrado, coluna faltando, falha no Outlook etc.)

.EXAMPLE
    Teste com os dados de exemplo (só gera o HTML, não mexe no Outlook):
    .\cherwell-weekly-report.ps1 -InputPath .\exemplos\incidentes_exemplo.csv -ReferenceDate 2026-11-23

.EXAMPLE
    Pega o CSV mais recente da pasta e abre o e-mail no Outlook para você revisar antes de enviar:
    .\cherwell-weekly-report.ps1 -InputPath "C:\scripts\exports" -SendEmail -To "gestor@empresa.com.br"

.EXAMPLE
    Export da interface do Cherwell (nomes de coluna = nomes de exibição, datas em pt-BR):
    .\cherwell-weekly-report.ps1 -InputPath .\export.csv -IdColumn "Incident ID" -StatusColumn "Status" -CategoryColumn "Category" -OwnerColumn "Owned By" -CreatedColumn "Created Date Time" -ClosedColumn "Closed Date Time"
#>

param(
    # Arquivo CSV ou pasta. Se for pasta, usa o CSV mais recente.
    [Parameter(Mandatory = $true)]
    [string]$InputPath,

    [string]$OutputFolder = ".\saida",

    [int]$Days = 7,

    [datetime]$ReferenceDate = (Get-Date),

    # Nomes das colunas no CSV. Os padrões batem com os nomes internos da API (cherwell-api-export.ps1).
    [string]$IdColumn = "IncidentID",
    [string]$StatusColumn = "Status",
    [string]$CategoryColumn = "Category",
    [string]$OwnerColumn = "OwnedBy",
    [string]$CreatedColumn = "CreatedDateTime",
    [string]$ClosedColumn = "ClosedDateTime",

    # Status que contam como "fechado" (comparação sem diferenciar maiúsculas).
    [string[]]$ClosedStatuses = @("Resolved", "Closed", "Resolvido", "Fechado", "Encerrado"),

    # Cultura das datas no CSV: "pt-BR" = dd/MM/yyyy, "en-US" = MM/dd/yyyy.
    [string]$DateCulture = "pt-BR",

    [string]$Encoding = "UTF8",

    # E-mail (só no Windows, com Outlook instalado).
    [switch]$SendEmail,
    [string[]]$To = @(),
    # Sem -SendNow o e-mail só é aberto na tela para revisão. Com -SendNow ele é enviado direto.
    [switch]$SendNow,

    # Quantas linhas do backlog envelhecido mostrar no corpo do e-mail (o CSV anexo tem todas).
    [int]$AgedRowsInEmail = 15
)

# ---------------------------------------------------------------------------
# Funções auxiliares
# ---------------------------------------------------------------------------

function ConvertTo-NullableDate {
    param(
        [string]$Text,
        [string]$CultureName
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $cultureList = @(
        [System.Globalization.CultureInfo]::GetCultureInfo($CultureName),
        [System.Globalization.CultureInfo]::InvariantCulture
    )

    foreach ($culture in $cultureList) {
        $parsedDate = [datetime]::MinValue
        $parsedOk = [datetime]::TryParse(
            $Text.Trim(),
            $culture,
            [System.Globalization.DateTimeStyles]::None,
            [ref]$parsedDate
        )

        if ($parsedOk) {
            return $parsedDate
        }
    }

    return $null
}

function Get-TextOrDefault {
    param(
        [string]$Text,
        [string]$DefaultText = "(sem valor)"
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $DefaultText
    }

    return $Text.Trim()
}

function Get-CountTable {
    param(
        $Items,
        [string]$PropertyName,
        [string]$Label,
        [int]$Top = 0
    )

    $groupList = @(
        @($Items | Where-Object { $null -ne $_ }) |
            Group-Object -Property $PropertyName |
            Sort-Object -Property @{ Expression = "Count"; Descending = $true }, @{ Expression = "Name"; Descending = $false }
    )

    if ($Top -gt 0) {
        $groupList = @($groupList | Select-Object -First $Top)
    }

    foreach ($groupItem in $groupList) {
        [PSCustomObject]@{
            $Label       = $groupItem.Name
            "Quantidade" = $groupItem.Count
        }
    }
}

function ConvertTo-HtmlSection {
    param(
        $Rows,
        [string]$Title
    )

    # @($null) tem 1 elemento; o filtro evita uma tabela vazia quando não há linhas.
    $rowList = @($Rows | Where-Object { $null -ne $_ })

    if ($rowList.Count -eq 0) {
        return "<h3>$Title</h3><p>Sem registros.</p>"
    }

    return ($rowList | ConvertTo-Html -Fragment -PreContent "<h3>$Title</h3>" | Out-String)
}

function Get-Median {
    param(
        [double[]]$Values
    )

    $sortedValues = @($Values | Sort-Object)

    if ($sortedValues.Count -eq 0) {
        return $null
    }

    $middleIndex = [int][math]::Floor($sortedValues.Count / 2)

    if ($sortedValues.Count % 2 -eq 1) {
        return $sortedValues[$middleIndex]
    }

    return ($sortedValues[$middleIndex - 1] + $sortedValues[$middleIndex]) / 2
}

function Send-OutlookReport {
    param(
        [string[]]$Recipients,
        [string]$Subject,
        [string]$HtmlBody,
        [string[]]$AttachmentPaths,
        [switch]$SendImmediately
    )

    $outlookApplication = New-Object -ComObject Outlook.Application
    $mailItem = $outlookApplication.CreateItem(0)
    $mailItem.To = ($Recipients -join "; ")
    $mailItem.Subject = $Subject
    $mailItem.HTMLBody = $HtmlBody

    foreach ($attachmentPath in $AttachmentPaths) {
        [void]$mailItem.Attachments.Add($attachmentPath)
    }

    if ($SendImmediately) {
        $mailItem.Send()
    }
    else {
        $mailItem.Display($false)
    }
}

# ---------------------------------------------------------------------------
# 1) Localiza o CSV
# ---------------------------------------------------------------------------

if (Test-Path -Path $InputPath -PathType Container) {
    $latestCsvFile = Get-ChildItem -Path $InputPath -Filter "*.csv" |
        Sort-Object -Property LastWriteTime -Descending |
        Select-Object -First 1

    if ($null -eq $latestCsvFile) {
        Write-Output "Nenhum CSV encontrado na pasta: $InputPath"
        exit 2
    }

    $csvPath = $latestCsvFile.FullName
}
elseif (Test-Path -Path $InputPath -PathType Leaf) {
    $csvPath = (Resolve-Path -Path $InputPath).Path
}
else {
    Write-Output "Caminho não encontrado: $InputPath"
    exit 2
}

Write-Output "Lendo: $csvPath"

# ---------------------------------------------------------------------------
# 2) Importa (detecta se o separador é ; ou ,)
# ---------------------------------------------------------------------------

$headerLine = Get-Content -Path $csvPath -TotalCount 1 -Encoding $Encoding
$semicolonCount = ($headerLine -split ";").Count - 1
$commaCount = ($headerLine -split ",").Count - 1

if ($semicolonCount -gt $commaCount) {
    $delimiter = ";"
}
else {
    $delimiter = ","
}

$rawRows = @(Import-Csv -Path $csvPath -Delimiter $delimiter -Encoding $Encoding)

# ---------------------------------------------------------------------------
# 3) Pastas e nomes de saída
# ---------------------------------------------------------------------------

if (-not (Test-Path -Path $OutputFolder)) {
    New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
}

$outputFolderFullPath = (Resolve-Path -Path $OutputFolder).Path
$fileDateStamp = $ReferenceDate.ToString("yyyy-MM-dd")
$htmlPath = Join-Path -Path $outputFolderFullPath -ChildPath "relatorio_semanal_$fileDateStamp.html"
$agedCsvPath = Join-Path -Path $outputFolderFullPath -ChildPath "backlog_envelhecido_$fileDateStamp.csv"

$periodStart = $ReferenceDate.Date.AddDays(-$Days)
$periodEnd = $ReferenceDate.Date
$periodLabel = "{0} a {1}" -f $periodStart.ToString("dd/MM/yyyy"), $periodEnd.AddDays(-1).ToString("dd/MM/yyyy")
$emailSubject = "Relatório semanal de chamados - $periodLabel"

$styleBlock = @"
<style>
body { font-family: Segoe UI, Arial, sans-serif; font-size: 13px; color: #222222; }
h2 { font-size: 18px; margin-bottom: 4px; }
h3 { font-size: 14px; margin: 18px 0 6px 0; }
table { border-collapse: collapse; }
th, td { border: 1px solid #cccccc; padding: 4px 10px; text-align: left; }
th { background: #f0f0f0; }
.nota { color: #666666; font-size: 11px; }
</style>
"@

# ---------------------------------------------------------------------------
# 4) Caso sem registros: gera só um aviso
# ---------------------------------------------------------------------------

if ($rawRows.Count -eq 0) {
    $emptyHtml = @"
<html><head><meta charset="utf-8">$styleBlock</head><body>
<h2>$emailSubject</h2>
<p>A busca não retornou registros para o período.</p>
<p class="nota">Arquivo de origem: $csvPath</p>
</body></html>
"@

    $emptyHtml | Out-File -FilePath $htmlPath -Encoding UTF8
    Write-Output "CSV sem registros. Aviso gerado em: $htmlPath"

    if ($SendEmail) {
        if ($To.Count -eq 0) {
            Write-Output "Informe pelo menos um destinatário com -To."
            exit 2
        }

        try {
            Send-OutlookReport -Recipients $To -Subject "$emailSubject (sem registros)" -HtmlBody $emptyHtml -AttachmentPaths @() -SendImmediately:$SendNow
        }
        catch {
            Write-Output "Falha ao montar o e-mail no Outlook: $($_.Exception.Message)"
            exit 2
        }
    }

    exit 1
}

# ---------------------------------------------------------------------------
# 5) Confere se as colunas existem
# ---------------------------------------------------------------------------

$availableColumns = @($rawRows[0].PSObject.Properties.Name)
$requiredColumns = @($IdColumn, $StatusColumn, $CategoryColumn, $OwnerColumn, $CreatedColumn, $ClosedColumn)
$missingColumns = @($requiredColumns | Where-Object { $availableColumns -notcontains $_ })

if ($missingColumns.Count -gt 0) {
    Write-Output "Colunas não encontradas no CSV: $($missingColumns -join ', ')"
    Write-Output "Colunas disponíveis: $($availableColumns -join ', ')"
    exit 2
}

# ---------------------------------------------------------------------------
# 6) Normaliza as linhas
# ---------------------------------------------------------------------------

$ticketList = @(
    foreach ($rawRow in $rawRows) {
        $statusText = Get-TextOrDefault -Text ([string]$rawRow.$StatusColumn)

        [PSCustomObject]@{
            Id       = Get-TextOrDefault -Text ([string]$rawRow.$IdColumn)
            Status   = $statusText
            Category = Get-TextOrDefault -Text ([string]$rawRow.$CategoryColumn)
            Owner    = Get-TextOrDefault -Text ([string]$rawRow.$OwnerColumn) -DefaultText "(sem técnico)"
            Created  = ConvertTo-NullableDate -Text ([string]$rawRow.$CreatedColumn) -CultureName $DateCulture
            Closed   = ConvertTo-NullableDate -Text ([string]$rawRow.$ClosedColumn) -CultureName $DateCulture
            IsClosed = ($ClosedStatuses -contains $statusText)
        }
    }
)

$rowsWithoutCreatedDate = @($ticketList | Where-Object { $null -eq $_.Created }).Count

# ---------------------------------------------------------------------------
# 7) Indicadores
# ---------------------------------------------------------------------------

$openedInPeriod = @(
    $ticketList | Where-Object {
        $null -ne $_.Created -and
        $_.Created -ge $periodStart -and
        $_.Created -lt $periodEnd
    }
)

$closedInPeriod = @(
    $ticketList | Where-Object {
        $_.IsClosed -and
        $null -ne $_.Closed -and
        $_.Closed -ge $periodStart -and
        $_.Closed -lt $periodEnd
    }
)

$currentBacklog = @($ticketList | Where-Object { -not $_.IsClosed })

$agedBacklog = @(
    $currentBacklog | Where-Object {
        $null -ne $_.Created -and
        ($periodEnd - $_.Created).TotalDays -gt $Days
    }
)

$resolutionHours = @(
    $closedInPeriod |
        Where-Object { $null -ne $_.Created } |
        ForEach-Object { ($_.Closed - $_.Created).TotalHours }
)

if ($resolutionHours.Count -gt 0) {
    $averageResolutionText = [math]::Round(($resolutionHours | Measure-Object -Average).Average, 1)
    $medianResolutionText = [math]::Round((Get-Median -Values $resolutionHours), 1)
}
else {
    $averageResolutionText = "-"
    $medianResolutionText = "-"
}

$summaryRows = @(
    [PSCustomObject]@{ "Indicador" = "Abertos no período";                  "Valor" = $openedInPeriod.Count }
    [PSCustomObject]@{ "Indicador" = "Fechados no período";                 "Valor" = $closedInPeriod.Count }
    [PSCustomObject]@{ "Indicador" = "Saldo (fechados - abertos)";          "Valor" = $closedInPeriod.Count - $openedInPeriod.Count }
    [PSCustomObject]@{ "Indicador" = "Backlog atual";                       "Valor" = $currentBacklog.Count }
    [PSCustomObject]@{ "Indicador" = "Backlog aberto há mais de $Days dias"; "Valor" = $agedBacklog.Count }
    [PSCustomObject]@{ "Indicador" = "Tempo médio de resolução (h)";        "Valor" = $averageResolutionText }
    [PSCustomObject]@{ "Indicador" = "Tempo mediano de resolução (h)";      "Valor" = $medianResolutionText }
)

$statusTable = Get-CountTable -Items $ticketList -PropertyName "Status" -Label "Status"
$openedByCategoryTable = Get-CountTable -Items $openedInPeriod -PropertyName "Category" -Label "Categoria" -Top 10
$closedByOwnerTable = Get-CountTable -Items $closedInPeriod -PropertyName "Owner" -Label "Técnico"
$backlogByOwnerTable = Get-CountTable -Items $currentBacklog -PropertyName "Owner" -Label "Técnico"

$agedRows = @(
    $agedBacklog |
        Sort-Object -Property Created |
        ForEach-Object {
            [PSCustomObject]@{
                "Chamado"        = $_.Id
                "Status"         = $_.Status
                "Categoria"      = $_.Category
                "Técnico"        = $_.Owner
                "Aberto em"      = $_.Created.ToString("dd/MM/yyyy HH:mm")
                "Dias em aberto" = [math]::Floor(($periodEnd - $_.Created).TotalDays)
            }
        }
)

# ---------------------------------------------------------------------------
# 8) Monta o HTML
# ---------------------------------------------------------------------------

$htmlSections = @(
    (ConvertTo-HtmlSection -Rows $summaryRows -Title "Resumo"),
    (ConvertTo-HtmlSection -Rows $openedByCategoryTable -Title "Abertos no período por categoria (top 10)"),
    (ConvertTo-HtmlSection -Rows $closedByOwnerTable -Title "Fechados no período por técnico"),
    (ConvertTo-HtmlSection -Rows $backlogByOwnerTable -Title "Backlog atual por técnico"),
    (ConvertTo-HtmlSection -Rows ($agedRows | Select-Object -First $AgedRowsInEmail) -Title "Backlog envelhecido (mais antigos primeiro)"),
    (ConvertTo-HtmlSection -Rows $statusTable -Title "Todos os registros do arquivo por status")
)

$generatedAtText = (Get-Date).ToString("dd/MM/yyyy HH:mm")

$footerNote = "Gerado em $generatedAtText a partir de: $csvPath ($($ticketList.Count) registros"

if ($rowsWithoutCreatedDate -gt 0) {
    $footerNote = "$footerNote; $rowsWithoutCreatedDate sem data de abertura legível - confira -DateCulture"
}

$footerNote = "$footerNote)."

$htmlDocument = @"
<html>
<head><meta charset="utf-8"><title>$emailSubject</title>$styleBlock</head>
<body>
<h2>$emailSubject</h2>
$($htmlSections -join "`n")
<p class="nota">$footerNote</p>
</body>
</html>
"@

$htmlDocument | Out-File -FilePath $htmlPath -Encoding UTF8

$attachmentList = @($csvPath)

if ($agedRows.Count -gt 0) {
    $agedRows | Export-Csv -Path $agedCsvPath -NoTypeInformation -Delimiter ";" -Encoding UTF8
    $attachmentList += $agedCsvPath
}

# ---------------------------------------------------------------------------
# 9) Resumo no console
# ---------------------------------------------------------------------------

Write-Output ""
Write-Output "Período: $periodLabel"
$summaryRows | Format-Table -AutoSize | Out-String | Write-Output
Write-Output "HTML: $htmlPath"

if ($agedRows.Count -gt 0) {
    Write-Output "Backlog envelhecido (CSV): $agedCsvPath"
}

if ($rowsWithoutCreatedDate -gt 0) {
    Write-Output "Atenção: $rowsWithoutCreatedDate linha(s) sem data de abertura legível. Confira -DateCulture."
}

# ---------------------------------------------------------------------------
# 10) E-mail (opcional)
# ---------------------------------------------------------------------------

if ($SendEmail) {
    if ($env:OS -ne "Windows_NT") {
        Write-Output "Envio pelo Outlook só funciona no Windows. Relatório gerado sem e-mail."
        exit 0
    }

    if ($To.Count -eq 0) {
        Write-Output "Informe pelo menos um destinatário com -To."
        exit 2
    }

    try {
        Send-OutlookReport -Recipients $To -Subject $emailSubject -HtmlBody $htmlDocument -AttachmentPaths $attachmentList -SendImmediately:$SendNow

        if ($SendNow) {
            Write-Output "E-mail enviado para: $($To -join ', ')"
        }
        else {
            Write-Output "E-mail aberto no Outlook para revisão."
        }
    }
    catch {
        Write-Output "Falha ao montar o e-mail no Outlook: $($_.Exception.Message)"
        exit 2
    }
}

exit 0
