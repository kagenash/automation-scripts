# ssh-setup.ps1

Script de configuração automatizada de ambiente SSH no Windows, com suporte a ProxyJump para acesso a servidores internos via host intermediário.

## O que faz

1. Cria a pasta `~/.ssh` se não existir
2. Ativa e configura o serviço `ssh-agent` para inicialização automática
3. Gera par de chaves RSA 4096 bits (apenas se não existir)
4. Cria arquivo `~/.ssh/config` com configuração de salto via ProxyJump
5. Cria atalho `.bat` na Área de Trabalho para conexão com um clique

## Requisitos

- Windows 10 / 11 com OpenSSH instalado
- PowerShell rodando como **Administrador** (necessário para configurar o `ssh-agent`)

## Uso

```powershell
# Abra o PowerShell como Administrador
.\ssh-setup.ps1
```

Ao finalizar, um ícone `CONECTAR_SERVIDOR.bat` será criado na Área de Trabalho.

## Topologia configurada

```
[Máquina local] → [jslxuser01 (jump host)] → [destino: 10.1.50.50]
```

Edite as variáveis no script para ajustar os hosts e IPs ao seu ambiente antes de executar.

## Notas

- A chave RSA não é sobrescrita se já existir
- O `ForwardAgent yes` no jump host permite usar a chave local no servidor de destino sem copiá-la
