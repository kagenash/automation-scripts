# solid-mass-deploy.ps1

Ferramenta GUI em PowerShell para deploy em massa de comandos via SSH em múltiplos servidores simultaneamente, com execução paralela via Runspaces e interface gráfica nativa do Windows.

## O que faz

- Executa um comando ou script em N servidores ao mesmo tempo via SSH (Posh-SSH)
- Interface gráfica com barra de progresso, contador e console de saída colorido por resultado
- Execução paralela com Runspaces — sem bloqueio da UI durante o deploy
- Botão de cancelamento com token thread-safe (cancela sem matar processos em andamento abruptamente)
- Resumo estatístico ao final: SUCCESS / FAILED / SKIPPED / DISPATCHED / CANCELLED
- Limite de linhas no console (mantém as últimas 1000 quando ultrapassa 1500) para evitar consumo excessivo de memória
- Oferta de abertura do arquivo de log ao terminar

## Requisitos

- PowerShell 5.1+
- Módulo `Posh-SSH` instalado:
  ```powershell
  Install-Module Posh-SSH -Force
  ```

## Uso

Execute o script diretamente pelo PowerShell:

```powershell
.\solid-mass-deploy.ps1
```

A interface abre automaticamente. Informe:
1. A lista de hosts alvos (um por linha ou via arquivo)
2. O comando a executar ou o script a enviar
3. Clique em **Deploy** para iniciar

## Cores do console

| Cor | Status |
|---|---|
| Verde | `[SUCCESS]` |
| Vermelho | `[FAILED]` |
| Amarelo | `[SKIPPED]` |
| Laranja | `[DISPATCHED]` |
| Cinza | `[CANCELLED]` |

## Notas técnicas

- Usa `List<T>` em vez de `array +=` para evitar complexidade O(n²) na construção da lista de alvos
- Timeouts configuráveis separadamente para comandos normais e disruptivos
- Guard contra lista de alvos vazia antes de iniciar o deploy
