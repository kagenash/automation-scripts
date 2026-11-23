<#
.SYNOPSIS
    Testa se o Cherwell consegue chamar scripts seus pela ação "Run a Program".

.DESCRIPTION
    Grava uma linha de log com data/hora, máquina, usuário e o ID do chamado.
    Se a linha aparecer no log depois de rodar a One-Step, a ponte funciona.

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

$logFolder = Split-Path -Path $LogPath -Parent

if (-not (Test-Path -Path $logFolder)) {
    New-Item -Path $logFolder -ItemType Directory -Force | Out-Null
}

$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$machineName = $env:COMPUTERNAME
$userName = $env:USERNAME
$logLine = "$timestamp | $machineName | $userName | $IncidentId"

Add-Content -Path $LogPath -Value $logLine

Write-Output "Log gravado em: $LogPath"
exit 0
