<#
.SYNOPSIS
    Testa se o Cherwell consegue chamar scripts seus pela ação "Run a Program".

.DESCRIPTION
    ATENÇÃO: script genérico, APENAS PARA TESTE E ESTUDO. Revise e adapte antes de qualquer uso em produção.

    Grava uma linha de log com data/hora, máquina, usuário e o ID do chamado.
    Se a linha aparecer no log depois de rodar a One-Step, a ponte funciona.

    Códigos de saída:
        0 = log gravado
        2 = não conseguiu gravar o log (permissão, caminho inválido etc.)

.EXAMPLE
    Teste local:
    .\cherwell-bridge-test.ps1 -IncidentId "INC-TESTE"

.EXAMPLE
    No Cherwell (ação Run a Program):
    Programa:   powershell.exe
    Argumentos: -NoProfile -ExecutionPolicy Bypass -File "C:\scripts\cherwell-bridge-test.ps1" -IncidentId "<token Incident ID>"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$IncidentId,

    [string]$LogPath = "C:\scripts\logs\ponte.log"
)

$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$machineName = $env:COMPUTERNAME
$userName = $env:USERNAME
$logLine = "$timestamp | $machineName | $userName | $IncidentId"

try {
    # Caminho só com o nome do arquivo (ex.: "ponte.log") não tem pasta para criar.
    $logFolder = Split-Path -Path $LogPath -Parent

    if (-not [string]::IsNullOrWhiteSpace($logFolder) -and -not (Test-Path -Path $logFolder)) {
        New-Item -Path $logFolder -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }

    # -ErrorAction Stop: sem isso uma falha de permissão passava despercebida e o script saía com 0.
    Add-Content -Path $LogPath -Value $logLine -ErrorAction Stop
}
catch {
    Write-Output "Falha ao gravar o log em ${LogPath}: $($_.Exception.Message)"
    exit 2
}

Write-Output "Log gravado em: $LogPath"
exit 0
