#Requires -RunAsAdministrator
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Script interativo de manutencao - Write-Host intencional para exibir status ao usuario')]
param()

# ============================================================
# Configuracao inicial
# ============================================================
$host.UI.RawUI.WindowTitle = 'Manutencao de Sistema do Windows'

$TOTAL = 28
$script:ETAPA = 0

function Show-Etapa {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Mensagem
    )
    $script:ETAPA++
    Write-Host ''
    Write-Host "[$script:ETAPA/$TOTAL] $Mensagem"
}

$scriptPath = $PSCommandPath

# ============================================================
# PRE-MANUTENCAO: Diagnostico do sistema
# ============================================================
try {
Clear-Host
Write-Host '======================================================'
Write-Host '  LIMPEZA PROFUNDA E MANUTENCAO DE SISTEMA'
Write-Host '======================================================'
Write-Host ''
Write-Host '>>> DIAGNOSTICO PRE-MANUTENCAO'
Write-Host ''

Write-Host '  --- TOP 10 PROCESSOS POR CPU ---'
Get-Process |
    Where-Object { $_.CPU -gt 0 } |
    Sort-Object -Property CPU -Descending |
    Select-Object -First 10 |
    Format-Table -Property Name,
        @{ Name = 'CPU (s)'; Expression = { [math]::Round($_.CPU, 1) } },
        @{ Name = 'RAM (MB)'; Expression = { [math]::Round($_.WorkingSet / 1MB, 1) } },
        Id -AutoSize

Write-Host '  --- TOP 10 PROCESSOS POR MEMORIA ---'
Get-Process |
    Sort-Object -Property WorkingSet -Descending |
    Select-Object -First 10 |
    Format-Table -Property Name,
        @{ Name = 'RAM (MB)'; Expression = { [math]::Round($_.WorkingSet / 1MB, 1) } },
        Id -AutoSize

Write-Host '  --- ESPACO EM DISCO ---'
Get-PSDrive -PSProvider FileSystem |
    Format-Table -Property Name,
        @{ Name = 'Usado (GB)'; Expression = { [math]::Round($_.Used / 1GB, 2) } },
        @{ Name = 'Livre (GB)'; Expression = { [math]::Round($_.Free / 1GB, 2) } } -AutoSize

Write-Host '  --- PROGRAMAS NA INICIALIZACAO ---'
Get-CimInstance -ClassName Win32_StartupCommand |
    Format-Table -Property Name, Location, Command -AutoSize -Wrap

Write-Host ''
Write-Host 'Iniciando manutencao automatica...'
Write-Host ''

# ============================================================
# [1] PLANO DE ENERGIA -> ALTO DESEMPENHO
# ============================================================
Show-Etapa 'Configurando plano de energia para Alto Desempenho...'
$highPerfGuid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
& powercfg /setactive $highPerfGuid 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host '  [AVISO] Plano Alto Desempenho nao encontrado. Criando via duplicacao...'
    & powercfg /duplicatescheme $highPerfGuid 2>$null
    & powercfg /setactive $highPerfGuid 2>$null
}
& powercfg /change standby-timeout-ac 0 2>$null
& powercfg /change hibernate-timeout-ac 0 2>$null
& powercfg /h off 2>$null
Write-Host '  Plano de Alto Desempenho ativo. Hibernacao desativada.'

# ============================================================
# [2] SAUDE DA IMAGEM DO SISTEMA (DISM)
# ============================================================
Show-Etapa 'Verificando e reparando imagem do sistema (DISM)...'
& dism /online /cleanup-image /checkhealth
if ($LASTEXITCODE -ne 0) { Write-Host '  [AVISO] CheckHealth detectou problemas.' }

Write-Host ''
Write-Host '  Verificando corrupcoes (ScanHealth)...'
& dism /online /cleanup-image /scanhealth
if ($LASTEXITCODE -ne 0) { Write-Host '  [AVISO] ScanHealth detectou corrupcoes - iniciando reparo...' }

Write-Host ''
Write-Host '  Reparando imagem (RestoreHealth)...'
& dism /online /cleanup-image /restorehealth
if ($LASTEXITCODE -ne 0) {
    Write-Host '  [AVISO] RestoreHealth falhou. Verifique a fonte de reparo.'
}
else {
    Write-Host '  Imagem do sistema reparada com sucesso.'
}

# ============================================================
# [3] VERIFICACAO DE ARQUIVOS DO SISTEMA (SFC)
# ============================================================
Show-Etapa 'Verificando arquivos do sistema (SFC /scannow)...'
& sfc /scannow
if ($LASTEXITCODE -ne 0) {
    Write-Host "  [AVISO] SFC encontrou problemas. Verifique CBS.log em $env:windir\Logs\CBS\"
}
else {
    Write-Host '  SFC sem problemas detectados.'
}

# ============================================================
# [4] SAUDE DO DISCO (SMART via CIM)
# ============================================================
Show-Etapa 'Verificando saude fisica dos discos (SMART)...'
$discos = Get-CimInstance -ClassName Win32_DiskDrive | Select-Object -Property Caption, Status
$todosOk = $true
foreach ($disco in $discos) {
    Write-Host "  $($disco.Caption): $($disco.Status)"
    if ($disco.Status -ne 'OK') { $todosOk = $false }
}
if (-not $todosOk) {
    Write-Host '  [ATENCAO] Um ou mais discos podem apresentar falha. Verifique com ferramenta do fabricante.'
}
else {
    Write-Host '  Todos os discos reportam status OK.'
}

# ============================================================
# [5] AJUSTES DE PERFORMANCE DO PROCESSADOR / SISTEMA
# ============================================================
Show-Etapa 'Ajustando parametros de performance do sistema...'
$null = New-Item -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' `
    -Name 'Win32PrioritySeparation' -Value 2 -Type DWord -Force
$null = New-Item -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' `
    -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' `
    -Name 'VisualFXSetting' -Value 2 -Type DWord -Force
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control' `
    -Name 'WaitToKillServiceTimeout' -Value '3000' -Type String -Force
Write-Host '  Parametros de performance ajustados.'

# ============================================================
# [7] LIMPEZA DE DIRETORIOS TEMPORARIOS
# ============================================================
Show-Etapa 'Limpando diretorios temporarios e Prefetch...'
Remove-Item -Path $env:TEMP -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$env:windir\Temp" -Recurse -Force -ErrorAction SilentlyContinue
$null = New-Item -Path $env:TEMP -ItemType Directory -Force -ErrorAction SilentlyContinue
$null = New-Item -Path "$env:windir\Temp" -ItemType Directory -Force -ErrorAction SilentlyContinue
if (Test-Path -Path "$env:windir\Prefetch") {
    Remove-Item -Path "$env:windir\Prefetch\*" -Force -ErrorAction SilentlyContinue
    Write-Host '  Prefetch limpo.'
}
Write-Host '  Diretorios temporarios limpos.'

# ============================================================
# [8] LIMPEZA DE COMPONENTES DISM
# ============================================================
Show-Etapa 'Limpando cache de componentes do sistema (DISM)...'
& dism /online /cleanup-image /startcomponentcleanup /resetbase 2>$null
Write-Host '  Componentes antigos removidos.'

# ============================================================
# [9] OTIMIZACAO DE DISCO (TRIM SSD / DEFRAG HDD)
# ============================================================
Show-Etapa 'Otimizando unidade C: (TRIM para SSD / Defrag para HDD)...'
try {
    Optimize-Volume -DriveLetter C -Verbose -ErrorAction Stop
}
catch {
    Write-Host '  [AVISO] Otimizacao de disco retornou erro. Verifique manualmente.'
}

# ============================================================
# [10] CACHE DE MINIATURAS E ICONES
# ============================================================
Show-Etapa 'Limpando cache de miniaturas e icones...'
Stop-Process -Name 'explorer' -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\thumbcache_*" `
    -Force -ErrorAction SilentlyContinue
$iconCache = "$env:LOCALAPPDATA\IconCache.db"
if (Test-Path -Path $iconCache) {
    $iconItem = Get-Item -Path $iconCache -Force -ErrorAction SilentlyContinue
    if ($null -ne $iconItem) {
        $iconItem.Attributes = 'Normal'
        Remove-Item -Path $iconCache -Force -ErrorAction SilentlyContinue
    }
}
& ie4uinit.exe -show 2>$null
Start-Process -FilePath 'explorer.exe'
Write-Host '  Cache de miniaturas e icones limpo.'

# ============================================================
# [11] CACHE DE FONTES DO WINDOWS
# ============================================================
Show-Etapa 'Limpando cache de fontes do Windows...'
Stop-Service -Name 'Windows Font Cache Service' -ErrorAction SilentlyContinue
Stop-Service -Name 'FontCache' -ErrorAction SilentlyContinue
Remove-Item -Path "$env:windir\ServiceProfiles\LocalService\AppData\Local\FontCache\*" `
    -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$env:windir\ServiceProfiles\LocalService\AppData\Local\FontCache*.dat" `
    -Force -ErrorAction SilentlyContinue
Start-Service -Name 'Windows Font Cache Service' -ErrorAction SilentlyContinue
Start-Service -Name 'FontCache' -ErrorAction SilentlyContinue
Write-Host '  Cache de fontes limpo.'

# ============================================================
# [12] CACHE DO INTERNET EXPLORER / EDGE LEGADO
# ============================================================
Show-Etapa 'Limpando cache do Internet Explorer / Edge legado...'
Stop-Process -Name 'msedge' -Force -ErrorAction SilentlyContinue
Stop-Process -Name 'iexplore' -Force -ErrorAction SilentlyContinue
Start-Process -FilePath 'RunDll32.exe' `
    -ArgumentList @('InetCpl.cpl,ClearMyTracksByProcess', '255') `
    -Wait -ErrorAction SilentlyContinue
if (Test-Path -Path "$env:LOCALAPPDATA\Microsoft\Windows\INetCache") {
    Remove-Item -Path "$env:LOCALAPPDATA\Microsoft\Windows\INetCache\*" `
        -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host '  Cache do IE e Edge legado limpo.'

# ============================================================
# [13] CACHE DO CHROME (TODOS OS PERFIS)
# ============================================================
Show-Etapa 'Limpando cache do Chrome (todos os perfis)...'
Stop-Process -Name 'chrome' -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

$chromeBase = "$env:LOCALAPPDATA\Google\Chrome\User Data"
if (-not (Test-Path -Path $chromeBase)) {
    Write-Host '  Chrome nao encontrado. Pulando.'
}
else {
    $perfisDiretorioChrome = Get-ChildItem -Path $chromeBase -Directory -Filter 'Profile *' |
        Select-Object -ExpandProperty Name
    $perfisChrome = @('Default') + $perfisDiretorioChrome
    foreach ($perfil in $perfisChrome) {
        $perfilPath = Join-Path -Path $chromeBase -ChildPath $perfil
        foreach ($cache in @('Cache', 'Code Cache', 'GPUCache')) {
            $cachePath = Join-Path -Path $perfilPath -ChildPath $cache
            if (Test-Path -Path $cachePath) {
                Remove-Item -Path $cachePath -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "  Cache '$cache' do perfil Chrome $perfil limpo."
            }
        }
    }
    Write-Host '  Limpeza do Chrome concluida.'
}

# ============================================================
# [14] LIXEIRA - CONFIGURAR EXCLUSAO IMEDIATA + ESVAZIAR
# ============================================================
Show-Etapa 'Configurando Lixeira para exclusao imediata e esvaziando...'
$volumes = Get-CimInstance -ClassName Win32_Volume |
    Where-Object { $_.DriveType -eq 3 -and $null -ne $_.DriveLetter }
foreach ($vol in $volumes) {
    $guid = $vol.DeviceID -replace '.*\{(.+)\}.*', '$1'
    $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\BitBucket\Volume\{$guid}"
    if (-not (Test-Path -Path $regPath)) {
        $null = New-Item -Path $regPath -Force
    }
    Set-ItemProperty -Path $regPath -Name 'NukeOnDelete' -Value 1 -Type DWord -Force
}
Clear-RecycleBin -Force -ErrorAction SilentlyContinue
Write-Host '  Lixeira esvaziada. Exclusao imediata ativada para todos os volumes.'

# ============================================================
# [15] LOGS DE EVENTOS DO WINDOWS
# ============================================================
Show-Etapa 'Limpando logs de eventos do Windows...'
$logsDeEventos = & wevtutil.exe el 2>$null
foreach ($log in $logsDeEventos) {
    & wevtutil.exe cl $log 2>$null
}
Write-Host '  Logs de eventos limpos.'

# ============================================================
# [16] LIMPEZA VIA CLEANMGR (AUTOMATICA)
# ============================================================
Show-Etapa 'Executando limpeza automatica de disco (cleanmgr)...'
$cleanmgrKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\Temporary Files',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\Recycle Bin',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\Thumbnail Cache',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\Internet Cache Files',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\Old ChkDsk Files'
)
foreach ($chave in $cleanmgrKeys) {
    if (-not (Test-Path -Path $chave)) { $null = New-Item -Path $chave -Force }
    Set-ItemProperty -Path $chave -Name 'StateFlags0100' -Value 2 -Type DWord -Force
}
Start-Process -FilePath 'cleanmgr.exe' -ArgumentList '/sagerun:100' -WindowStyle Hidden -Wait
Write-Host '  Limpeza de disco concluida.'

# ============================================================
# [17] PASTA DE DOWNLOADS - APAGAR ARQUIVOS COM +30 DIAS
# ============================================================
Show-Etapa 'Removendo arquivos da pasta Downloads com mais de 30 dias...'
$downloadsPath = "$env:USERPROFILE\Downloads"
if (Test-Path -Path $downloadsPath) {
    $corte = (Get-Date).AddDays(-30)
    Get-ChildItem -Path $downloadsPath -Recurse -File |
        Where-Object { $_.LastWriteTime -lt $corte } |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $downloadsPath -Recurse -Directory |
        Sort-Object -Property FullName -Descending |
        Where-Object { (Get-ChildItem -Path $_.FullName).Count -eq 0 } |
        Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Host '  Arquivos com mais de 30 dias removidos da pasta Downloads.'
}
else {
    Write-Host '  Pasta Downloads nao encontrada.'
}

# ============================================================
# [18] VERIFICACAO DE SERVICOS CRITICOS
# ============================================================
Show-Etapa 'Verificando servicos criticos do sistema...'
$servicosCriticos = @('Winmgmt', 'RpcSs', 'EventLog', 'W32Time')
foreach ($nomeServico in $servicosCriticos) {
    $servico = Get-Service -Name $nomeServico -ErrorAction SilentlyContinue
    if ($null -ne $servico -and $servico.Status -ne 'Running') {
        Write-Host "  [AVISO] Servico $nomeServico nao esta rodando. Tentando iniciar..."
        Start-Service -Name $nomeServico -ErrorAction SilentlyContinue
    }
}
Write-Host '  Verificacao de servicos concluida.'

# ============================================================
# [19] OTIMIZACAO DE INICIALIZACAO
# ============================================================
Show-Etapa 'Otimizando inicializacao do sistema...'

# Remove delay artificial de inicializacao do Explorer
$serializePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize'
$null = New-Item -Path $serializePath -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path $serializePath -Name 'StartupDelayInMSec' -Value 0 -Type DWord -Force
Write-Host '  Delay de inicializacao do Explorer removido.'

# Desativa o Fast Startup (causa boots sujos e problemas de resume)
$powerPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
$null = New-Item -Path $powerPath -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path $powerPath -Name 'HiberbootEnabled' -Value 0 -Type DWord -Force
Write-Host '  Fast Startup (inicializacao rapida hibrida) desativado.'

Write-Host '  Programas na inicializacao detectados:'
Get-CimInstance -ClassName Win32_StartupCommand |
    Format-Table -Property Name, Location, Command -AutoSize -Wrap

# ============================================================
# [20] SERVICOS DE TELEMETRIA E DIAGNOSTICO
# ============================================================
Show-Etapa 'Desativando servicos de telemetria e diagnostico...'
$servicosTelemetria = @('DiagTrack', 'dmwappushservice', 'WerSvc', 'PcaSvc')
foreach ($nomeSvc in $servicosTelemetria) {
    $svc = Get-Service -Name $nomeSvc -ErrorAction SilentlyContinue
    if ($null -ne $svc) {
        Stop-Service -Name $nomeSvc -Force -ErrorAction SilentlyContinue
        Set-Service -Name $nomeSvc -StartupType Disabled -ErrorAction SilentlyContinue
        Write-Host "  Servico '$nomeSvc' desativado."
    }
}
# Desativa coleta de dados via politica de registro
$telemetryPolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
$null = New-Item -Path $telemetryPolicyPath -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path $telemetryPolicyPath -Name 'AllowTelemetry' -Value 0 -Type DWord -Force
Write-Host '  Telemetria de dados desativada via politica.'

# ============================================================
# [21] APPS EM SEGUNDO PLANO + SYSMAIN
# ============================================================
Show-Etapa 'Desativando apps em segundo plano e avaliando SysMain...'

# Desativa apps universais em segundo plano
$bgAppsPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications'
$null = New-Item -Path $bgAppsPath -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path $bgAppsPath -Name 'GlobalUserDisabled' -Value 1 -Type DWord -Force
$searchBgPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'
$null = New-Item -Path $searchBgPath -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path $searchBgPath -Name 'BackgroundAppGlobalToggle' -Value 0 -Type DWord -Force
Write-Host '  Apps em segundo plano desativados.'

# Avalia SysMain: desativa em HDD, mantém em SSD (nativo em SSD e inutil em HDD)
try {
    $systemDriveLetter = $env:SystemDrive.TrimEnd(':')
    $partition = Get-Partition |
        Where-Object { $_.DriveLetter -eq $systemDriveLetter } |
        Select-Object -First 1
    $physDisk = Get-PhysicalDisk |
        Where-Object { $_.DeviceId -eq $partition.DiskNumber } |
        Select-Object -First 1
    $isSSD = $physDisk.MediaType -eq 'SSD'
}
catch {
    $isSSD = $false
}

$sysMain = Get-Service -Name 'SysMain' -ErrorAction SilentlyContinue
if ($null -ne $sysMain) {
    if (-not $isSSD) {
        Stop-Service -Name 'SysMain' -Force -ErrorAction SilentlyContinue
        Set-Service -Name 'SysMain' -StartupType Disabled -ErrorAction SilentlyContinue
        Write-Host '  SysMain desativado (HDD detectado - previne picos de uso de disco).'
    }
    else {
        Write-Host '  SysMain mantido ativo (SSD detectado).'
    }
}

# ============================================================
# [22] CACHE DO EDGE CHROMIUM (TODOS OS PERFIS)
# ============================================================
Show-Etapa 'Limpando cache do Microsoft Edge Chromium (todos os perfis)...'
Stop-Process -Name 'msedge' -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

$edgeBase = "$env:LOCALAPPDATA\Microsoft\Edge\User Data"
if (-not (Test-Path -Path $edgeBase)) {
    Write-Host '  Edge Chromium nao encontrado. Pulando.'
}
else {
    $perfisDiretorioEdge = Get-ChildItem -Path $edgeBase -Directory -Filter 'Profile *' |
        Select-Object -ExpandProperty Name
    $perfisEdge = @('Default') + $perfisDiretorioEdge
    foreach ($perfil in $perfisEdge) {
        $perfilPath = Join-Path -Path $edgeBase -ChildPath $perfil
        foreach ($cache in @('Cache', 'Code Cache', 'GPUCache')) {
            $cachePath = Join-Path -Path $perfilPath -ChildPath $cache
            if (Test-Path -Path $cachePath) {
                Remove-Item -Path $cachePath -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "  Cache '$cache' do perfil Edge $perfil limpo."
            }
        }
    }
    Write-Host '  Limpeza do Edge Chromium concluida.'
}

# ============================================================
# [23] CACHE DO WINDOWS UPDATE E DELIVERY OPTIMIZATION
# ============================================================
Show-Etapa 'Limpando cache do Windows Update e Delivery Optimization...'

Stop-Service -Name 'wuauserv' -Force -ErrorAction SilentlyContinue
Stop-Service -Name 'bits' -Force -ErrorAction SilentlyContinue
Stop-Service -Name 'DoSvc' -Force -ErrorAction SilentlyContinue

# Remove downloads de atualizacoes ja instaladas
$wuDownloadPath = "$env:windir\SoftwareDistribution\Download"
if (Test-Path -Path $wuDownloadPath) {
    Remove-Item -Path "$wuDownloadPath\*" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host '  Cache de downloads do Windows Update limpo.'
}

# Remove cache do Delivery Optimization via cmdlet nativo (Win10 1803+)
try {
    Delete-DeliveryOptimizationCache -Force -ErrorAction Stop
    Write-Host '  Cache do Delivery Optimization limpo via cmdlet.'
}
catch {
    # Fallback: remocao direta da pasta
    $doPath = "$env:windir\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache"
    if (Test-Path -Path $doPath) {
        Remove-Item -Path "$doPath\*" -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host '  Cache do Delivery Optimization limpo via pasta.'
    }
}

Start-Service -Name 'wuauserv' -ErrorAction SilentlyContinue
Start-Service -Name 'bits' -ErrorAction SilentlyContinue
Start-Service -Name 'DoSvc' -ErrorAction SilentlyContinue
Write-Host '  Servicos do Windows Update reiniciados.'

# ============================================================
# [24] DNS E OTIMIZACAO DE REDE
# ============================================================
Show-Etapa 'Limpando cache DNS e otimizando adaptadores de rede...'

# Limpa cache DNS
Clear-DnsClientCache
Write-Host '  Cache DNS limpo.'

# Garante que o auto-tuning TCP esta em modo normal (melhor throughput)
& netsh int tcp set global autotuninglevel=normal 2>$null
Write-Host '  TCP auto-tuning definido para normal.'

# Desativa Energy Efficient Ethernet nos adaptadores ativos (pode causar latencia)
$adaptadoresAtivos = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
foreach ($adaptador in $adaptadoresAtivos) {
    Set-NetAdapterAdvancedProperty -Name $adaptador.Name `
        -RegistryKeyword 'EEE' -RegistryValue 0 -ErrorAction SilentlyContinue
    Set-NetAdapterAdvancedProperty -Name $adaptador.Name `
        -RegistryKeyword '*EEE' -RegistryValue 0 -ErrorAction SilentlyContinue
    Set-NetAdapterPowerManagement -Name $adaptador.Name `
        -WakeOnMagicPacket Disabled `
        -WakeOnPattern Disabled `
        -ErrorAction SilentlyContinue
    Write-Host "  Economia de energia desativada no adaptador '$($adaptador.Name)'."
}

# ============================================================
# [25] OTIMIZACAO DE ASSEMBLIES .NET (NGEN)
# ============================================================
Show-Etapa 'Otimizando assemblies .NET via tarefas agendadas (NGEN)...'

$ngenTasks = @(
    @{ Path = '\Microsoft\Windows\.NET Framework\'; Name = '.NET Framework NGEN v4.0.30319 64' },
    @{ Path = '\Microsoft\Windows\.NET Framework\'; Name = '.NET Framework NGEN v4.0.30319' },
    @{ Path = '\Microsoft\Windows\.NET Framework\'; Name = '.NET Framework NGEN v2.0.50727 64' },
    @{ Path = '\Microsoft\Windows\.NET Framework\'; Name = '.NET Framework NGEN v2.0.50727 32' }
)
foreach ($ngenTask in $ngenTasks) {
    $task = Get-ScheduledTask -TaskPath $ngenTask.Path -TaskName $ngenTask.Name -ErrorAction SilentlyContinue
    if ($null -ne $task) {
        Start-ScheduledTask -TaskPath $ngenTask.Path -TaskName $ngenTask.Name -ErrorAction SilentlyContinue
        Write-Host "  Tarefa NGEN '$($ngenTask.Name)' iniciada."
    }
}
Write-Host '  Assemblies .NET serao otimizados em segundo plano.'

# ============================================================
# [26] RECONSTRUCAO DO INDICE DO WINDOWS SEARCH
# ============================================================
Show-Etapa 'Reconstruindo indice de pesquisa do Windows Search...'

Stop-Service -Name 'WSearch' -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3

$searchDataPath = "$env:ProgramData\Microsoft\Search\Data\Applications\Windows"
if (Test-Path -Path $searchDataPath) {
    Remove-Item -Path "$searchDataPath\*" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host '  Indice de pesquisa removido - sera reconstruido automaticamente.'
}

Start-Service -Name 'WSearch' -ErrorAction SilentlyContinue
Write-Host '  Windows Search reiniciado. Reconstrucao ocorre em segundo plano.'

# ============================================================
# [27] OTIMIZACAO DO ARQUIVO DE PAGINACAO (PAGEFILE)
# ============================================================
Show-Etapa 'Otimizando arquivo de paginacao (pagefile)...'

$ramTotal = (Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory
$ramGB = [math]::Round($ramTotal / 1GB, 1)
Write-Host "  RAM total detectada: $ramGB GB"

# Define gerenciamento automatico do pagefile pelo sistema
$cs = Get-CimInstance -ClassName Win32_ComputerSystem
if (-not $cs.AutomaticManagedPagefile) {
    Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $true }
    Write-Host '  Pagefile configurado para gerenciamento automatico pelo sistema.'
}
else {
    Write-Host '  Pagefile ja esta em modo de gerenciamento automatico.'
}

# ============================================================
# [28] AUDITORIA DE TAREFAS AGENDADAS DE TERCEIROS
# ============================================================
Show-Etapa 'Auditando tarefas agendadas de terceiros...'

Write-Host '  Tarefas agendadas ativas fora dos caminhos do sistema:'
Get-ScheduledTask |
    Where-Object {
        $_.TaskPath -notmatch '^\\Microsoft\\' -and
        $_.State -eq 'Ready'
    } |
    Select-Object -Property TaskName, TaskPath,
        @{ Name = 'Autor'; Expression = { $_.Principal.UserId } } |
    Format-Table -AutoSize -Wrap

Write-Host '  [INFO] Revise tarefas desconhecidas e desative as desnecessarias via Task Scheduler.'

# ============================================================
# [29] AGENDAMENTO DE CHKDSK E REINICIALIZACAO
# ============================================================
Show-Etapa 'Agendando verificacao de disco (CHKDSK) e reiniciando...'

& fsutil dirty set C: 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host '  [AVISO] Nao foi possivel agendar CHKDSK via fsutil.'
    Write-Host "  Execute 'chkdsk C: /f /r' manualmente apos o reboot."
}

    Write-Host ''
    Write-Host '======================================================'
    Write-Host '  MANUTENCAO CONCLUIDA - REINICIANDO EM 15 SEGUNDOS'
    Write-Host '======================================================'
    Write-Host ''

    & shutdown.exe /r /t 15 /c 'Manutencao concluida - reinicializacao automatica'
}
finally {
    # Auto-exclusao: cmd externo aguarda o script encerrar e deleta o arquivo
    if (-not [string]::IsNullOrEmpty($scriptPath) -and (Test-Path -Path $scriptPath)) {
        Start-Process -FilePath 'cmd.exe' `
            -ArgumentList "/c ping 127.0.0.1 -n 5 >nul & del /f /q `"$scriptPath`"" `
            -WindowStyle Hidden
    }
}
