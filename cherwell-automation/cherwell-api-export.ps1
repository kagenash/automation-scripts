<#
.SYNOPSIS
    Esqueleto para quando você tiver um Client ID: busca registros pela REST API do Cherwell e salva em CSV.
    O CSV gerado já sai no formato que o cherwell-weekly-report.ps1 espera (nomes internos dos campos).

.DESCRIPTION
    Fluxo:
        1. Login (token OAuth2) com Client ID + usuário/senha do Cherwell
        2. Descobre o busObId do Business Object (ex.: Incident)
        3. Lê o schema para traduzir nome do campo -> fieldId
        4. Busca com filtro de data, paginando
        5. Salva em CSV e faz logout (libera a licença)

    Antes de rodar pela primeira vez, salve a credencial (fica criptografada para o seu usuário do Windows):
        .\cherwell-api-export.ps1 -SaveCredential

    Dica: explore os endpoints no Swagger: https://SEU-SERVIDOR/CherwellAPI/swagger/ui/index

    Códigos de saída:
        0 = CSV gerado
        1 = busca sem resultados
        2 = erro

.EXAMPLE
    .\cherwell-api-export.ps1 -ServerUrl "https://cherwell.empresa.local" -ClientId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -Days 30

.EXAMPLE
    Encadeado com o relatório:
    .\cherwell-api-export.ps1 -ServerUrl "https://cherwell.empresa.local" -ClientId "..." -OutputCsv ".\exports\api.csv"
    .\cherwell-weekly-report.ps1 -InputPath ".\exports\api.csv" -DateCulture "en-US"
#>

# $CredentialPath é o caminho do arquivo, não a senha: o aviso do analisador é falso positivo.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingPlainTextForPassword", "CredentialPath")]
[CmdletBinding(DefaultParameterSetName = "Buscar")]
param(
    [Parameter(Mandatory = $true, ParameterSetName = "SalvarCredencial")]
    [switch]$SaveCredential,

    [Parameter(Mandatory = $true, ParameterSetName = "Buscar")]
    [string]$ServerUrl,

    [Parameter(Mandatory = $true, ParameterSetName = "Buscar")]
    [string]$ClientId,

    # Export-Clixml só criptografa (DPAPI) no Windows. Não copie este arquivo para outra máquina.
    [string]$CredentialPath = (Join-Path -Path $HOME -ChildPath "cherwell_api_credencial.xml"),

    [Parameter(ParameterSetName = "Buscar")]
    [ValidateSet("Internal", "Windows", "LDAP", "SAML", "Auto")]
    [string]$AuthMode = "Internal",

    [Parameter(ParameterSetName = "Buscar")]
    [string]$BusinessObjectName = "Incident",

    # Nomes internos dos campos. Se algum não existir, o script lista os disponíveis.
    [Parameter(ParameterSetName = "Buscar")]
    [string[]]$FieldNames = @("IncidentID", "Status", "Priority", "Category", "ShortDescription", "OwnedBy", "CreatedDateTime", "ClosedDateTime"),

    # Campo de data usado no filtro "maior que hoje - Days". Deixe vazio para não filtrar.
    [Parameter(ParameterSetName = "Buscar")]
    [string]$DateFieldName = "CreatedDateTime",

    # Atenção: filtrar por data de abertura deixa de fora chamados antigos ainda abertos.
    # Para o backlog envelhecido completo, use um valor maior aqui ou faça uma segunda busca por Status.
    [Parameter(ParameterSetName = "Buscar")]
    [int]$Days = 30,

    # Formato da data no filtro. Depende da "Culture" configurada no Client ID:
    # en-US -> "MM/dd/yyyy" | pt-BR -> "dd/MM/yyyy"
    [Parameter(ParameterSetName = "Buscar")]
    [string]$DateFormat = "MM/dd/yyyy",

    [Parameter(ParameterSetName = "Buscar")]
    [int]$PageSize = 500,

    [Parameter(ParameterSetName = "Buscar")]
    [int]$MaxPages = 100,

    [Parameter(ParameterSetName = "Buscar")]
    [string]$OutputCsv = ".\saida\cherwell_api_export.csv"
)

# ---------------------------------------------------------------------------
# Modo 1: salvar credencial
# ---------------------------------------------------------------------------

if ($SaveCredential) {
    $credentialToSave = Get-Credential -Message "Usuário e senha do Cherwell"
    $credentialToSave | Export-Clixml -Path $CredentialPath
    Write-Output "Credencial salva em: $CredentialPath"
    exit 0
}

# ---------------------------------------------------------------------------
# Modo 2: buscar
# ---------------------------------------------------------------------------

if (-not (Test-Path -Path $CredentialPath)) {
    Write-Output "Credencial não encontrada. Rode antes: .\cherwell-api-export.ps1 -SaveCredential"
    exit 2
}

# Windows PowerShell 5.1 pode não usar TLS 1.2 por padrão.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$apiBaseUrl = $ServerUrl.TrimEnd("/") + "/CherwellAPI"
$requestHeaders = $null
$exitCode = 0

try {
    # 1) Login
    $storedCredential = Import-Clixml -Path $CredentialPath

    $tokenBody = @{
        grant_type = "password"
        client_id  = $ClientId
        username   = $storedCredential.UserName
        password   = $storedCredential.GetNetworkCredential().Password
    }

    $tokenUri = "$apiBaseUrl/token?auth_mode=$AuthMode&api_key=$ClientId"
    $tokenResponse = Invoke-RestMethod -Method Post -Uri $tokenUri -Body $tokenBody -ContentType "application/x-www-form-urlencoded"

    $requestHeaders = @{
        Authorization = "Bearer $($tokenResponse.access_token)"
        Accept        = "application/json"
    }

    Write-Output "Login OK."

    # 2) busObId do Business Object
    $summaryUri = "$apiBaseUrl/api/V1/getbusinessobjectsummary/busobname/$BusinessObjectName"
    $summaryResponse = Invoke-RestMethod -Method Get -Uri $summaryUri -Headers $requestHeaders
    $businessObjectId = @($summaryResponse)[0].busObId

    if ([string]::IsNullOrWhiteSpace($businessObjectId)) {
        throw "Business Object '$BusinessObjectName' não encontrado."
    }

    # 3) Schema: nome do campo -> fieldId
    $schemaUri = "$apiBaseUrl/api/V1/getbusinessobjectschema/busobid/$businessObjectId"
    $schemaResponse = Invoke-RestMethod -Method Get -Uri $schemaUri -Headers $requestHeaders

    $fieldIdByName = @{}

    foreach ($fieldDefinition in $schemaResponse.fieldDefinitions) {
        $fieldIdByName[$fieldDefinition.name] = $fieldDefinition.fieldId
    }

    $fieldsToCheck = @($FieldNames)

    if (-not [string]::IsNullOrWhiteSpace($DateFieldName)) {
        $fieldsToCheck += $DateFieldName
    }

    $missingFieldNames = @($fieldsToCheck | Where-Object { -not $fieldIdByName.ContainsKey($_) } | Select-Object -Unique)

    if ($missingFieldNames.Count -gt 0) {
        $availableFieldNames = ($fieldIdByName.Keys | Sort-Object) -join ", "
        throw "Campos não encontrados: $($missingFieldNames -join ', '). Disponíveis: $availableFieldNames"
    }

    $selectedFieldIds = @($FieldNames | ForEach-Object { $fieldIdByName[$_] })

    # 4) Filtro
    $searchFilters = @()

    if (-not [string]::IsNullOrWhiteSpace($DateFieldName)) {
        $startDateText = (Get-Date).Date.AddDays(-$Days).ToString($DateFormat, [System.Globalization.CultureInfo]::InvariantCulture)

        $searchFilters += @{
            fieldId  = $fieldIdByName[$DateFieldName]
            operator = "gt"
            value    = $startDateText
        }
    }

    # 5) Busca paginada
    $collectedRows = New-Object System.Collections.Generic.List[object]
    $pageNumber = 1
    $totalRows = 0

    do {
        $searchRequest = @{
            busObId          = $businessObjectId
            fields           = $selectedFieldIds
            filters          = $searchFilters
            includeAllFields = $false
            pageNumber       = $pageNumber
            pageSize         = $PageSize
        }

        $searchBody = $searchRequest | ConvertTo-Json -Depth 6
        $searchUri = "$apiBaseUrl/api/V1/getsearchresults"
        $searchResponse = Invoke-RestMethod -Method Post -Uri $searchUri -Headers $requestHeaders -Body $searchBody -ContentType "application/json"

        $pageObjects = @($searchResponse.businessObjects)
        $totalRows = [int]$searchResponse.totalRows

        foreach ($businessObject in $pageObjects) {
            $rowValues = [ordered]@{}

            foreach ($fieldName in $FieldNames) {
                $rowValues[$fieldName] = ""
            }

            foreach ($fieldValue in $businessObject.fields) {
                if ($rowValues.Contains($fieldValue.name)) {
                    $rowValues[$fieldValue.name] = $fieldValue.value
                }
            }

            $collectedRows.Add([PSCustomObject]$rowValues)
        }

        Write-Output "Página $pageNumber : $($pageObjects.Count) registros (total informado: $totalRows)"
        $pageNumber++
    } while ($pageObjects.Count -gt 0 -and $collectedRows.Count -lt $totalRows -and $pageNumber -le $MaxPages)

    if ($collectedRows.Count -lt $totalRows) {
        Write-Warning "Exportação incompleta: $($collectedRows.Count) de $totalRows registros (limite de -MaxPages $MaxPages atingido). Aumente -MaxPages ou -PageSize."
    }

    if ($collectedRows.Count -eq 0) {
        Write-Output "Nenhum registro encontrado."
        $exitCode = 1
    }
    else {
        $outputFolder = Split-Path -Parent $OutputCsv

        if (-not [string]::IsNullOrWhiteSpace($outputFolder) -and -not (Test-Path -Path $outputFolder)) {
            New-Item -Path $outputFolder -ItemType Directory -Force | Out-Null
        }

        $collectedRows | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
        Write-Output "CSV salvo: $OutputCsv ($($collectedRows.Count) registros)"
    }
}
catch {
    Write-Output "Erro: $($_.Exception.Message)"

    # No PowerShell 5.1 a exceção só diz "(400) Bad Request"; o motivo real que o Cherwell
    # devolve (ex.: "Invalid client_id", campo inválido no filtro) vem no corpo da resposta.
    if ($_.ErrorDetails -and -not [string]::IsNullOrWhiteSpace($_.ErrorDetails.Message)) {
        Write-Output "Resposta do Cherwell: $($_.ErrorDetails.Message)"
    }

    $exitCode = 2
}
finally {
    # Logout: encerra a sessão e libera a licença.
    if ($null -ne $requestHeaders) {
        try {
            Invoke-RestMethod -Method Delete -Uri "$apiBaseUrl/api/V1/logout" -Headers $requestHeaders | Out-Null
            Write-Output "Logout OK."
        }
        catch {
            Write-Output "Aviso: logout falhou ($($_.Exception.Message))."
        }
    }
}

exit $exitCode
