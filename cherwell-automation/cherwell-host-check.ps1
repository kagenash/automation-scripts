<#
.SYNOPSIS
    Testa se um host está online (ping ou porta TCP) e devolve o resultado como código de saída.

.DESCRIPTION
    O Cherwell não lê texto de volta do script, só o código de saída.
    Use "Store Exit Code from Program" na One-Step e decida a próxima ação pelo valor:
        0 = online
        1 = offline / sem resposta
        2 = erro (host não resolve no DNS, nome vazio etc.)

.EXAMPLE
    Ping simples:
    .\cherwell-host-check.ps1 -HostName "srv-arquivos01"

.EXAMPLE
    Teste da porta do RDP (3389):
    .\cherwell-host-check.ps1 -HostName "10.0.0.15" -Port 3389

.EXAMPLE
    No Cherwell (ação Run a Program):
    Programa:   powershell.exe
    Argumentos: -NoProfile -ExecutionPolicy Bypass -File "C:\scripts\cherwell-host-check.ps1" -HostName "<token do host/CI>"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$HostName,

    [int]$Port = 0,

    [int]$TimeoutMilliseconds = 3000
)

# 1) Resolve o nome no DNS. Se falhar, o problema é de cadastro ou de rede: exit 2.
try {
    $resolvedAddresses = [System.Net.Dns]::GetHostAddresses($HostName)
}
catch {
    Write-Output "Não foi possível resolver o host: $HostName"
    exit 2
}

$isOnline = $false

# 2a) Com porta: tenta abrir uma conexão TCP.
if ($Port -gt 0) {
    $tcpClient = New-Object System.Net.Sockets.TcpClient

    try {
        $connectTask = $tcpClient.ConnectAsync($HostName, $Port)
        $finishedInTime = $connectTask.Wait($TimeoutMilliseconds)
        $isOnline = $finishedInTime -and $tcpClient.Connected
    }
    catch {
        $isOnline = $false
    }
    finally {
        $tcpClient.Close()
    }
}
# 2b) Sem porta: ping (ICMP).
else {
    $pingSender = New-Object System.Net.NetworkInformation.Ping

    try {
        $pingReply = $pingSender.Send($HostName, $TimeoutMilliseconds)
        $isOnline = ($pingReply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success)
    }
    catch {
        $isOnline = $false
    }
    finally {
        $pingSender.Dispose()
    }
}

# 3) Resultado
$firstAddress = $resolvedAddresses[0].IPAddressToString

if ($isOnline) {
    Write-Output "ONLINE: $HostName ($firstAddress)"
    exit 0
}
else {
    Write-Output "OFFLINE: $HostName ($firstAddress)"
    exit 1
}
