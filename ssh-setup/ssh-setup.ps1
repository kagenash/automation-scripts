# 1. Garante que a pasta .ssh existe
$sshPath = "$HOME\.ssh"
if (!(Test-Path $sshPath)) {
    New-Item -ItemType Directory -Path $sshPath | Out-Null
}

# 2. Ativa o Agente SSH (Necessário abrir o PS como Administrador)
Write-Host "--- Configurando Servico de Chave ---" -ForegroundColor Cyan
try {
    Set-Service -Name ssh-agent -StartupType Automatic -ErrorAction Stop
    Start-Service ssh-agent -ErrorAction SilentlyContinue
} catch {
    Write-Host "AVISO: Rode como Administrador para ativar o Agente automaticamente." -ForegroundColor Red
}

# 3. Gera a chave SSH (Apenas se nao existir)
if (!(Test-Path "$sshPath\id_rsa")) {
    Write-Host "--- Gerando Cracha Digital (Chave SSH) ---" -ForegroundColor Yellow
    ssh-keygen -t rsa -b 4096 -f "$sshPath\id_rsa" -N '""'
}

# 4. Cria o arquivo de configuração de saltos
Write-Host "--- Criando Atalhos de Conexao ---" -ForegroundColor Cyan
$configContent = @"
Host jslxuser01
    ForwardAgent yes
    User $($env:USERNAME)

Host destino
    HostName 10.1.50.50
    User $($env:USERNAME)
    ProxyJump jslxuser01
"@
$configContent | Out-File -FilePath "$sshPath\config" -Encoding ASCII

# 5. Cria o atalho .bat na Area de Trabalho
$batPath = "$HOME\Desktop\CONECTAR_SERVIDOR.bat"
"@echo off
title Conexao 10.1.50.50
ssh-add `"%USERPROFILE%\.ssh\id_rsa`" 2>nul
echo Conectando ao Servidor...
ssh destino
pause" | Out-File -FilePath $batPath -Encoding ASCII

Write-Host "`nFINALIZADO!" -ForegroundColor Green
Write-Host "Um icone foi criado na sua Area de Trabalho."