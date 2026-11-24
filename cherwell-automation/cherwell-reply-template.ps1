<#
.SYNOPSIS
    Monta um texto de resposta padrão com os dados do chamado e copia para a área de transferência.

.DESCRIPTION
    ATENÇÃO: script genérico, APENAS PARA TESTE E ESTUDO. Revise e adapte antes de qualquer uso em produção.

    Chamado pela One-Step via "Run a Program", recebendo os dados por Tokens.
    Depois é só colar (Ctrl+V) no e-mail ou no journal.

    Modelos disponíveis:
        encerramento, aguardando_usuario, visita_tecnica, escalonamento

.EXAMPLE
    Teste local:
    .\cherwell-reply-template.ps1 -TemplateName encerramento -IncidentId "INC-101234" -CustomerName "Maria Silva" -Category "Impressora"

.EXAMPLE
    No Cherwell (ação Run a Program):
    Programa:   powershell.exe
    Argumentos: -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\scripts\cherwell-reply-template.ps1" -TemplateName encerramento -IncidentId "<token ID>" -CustomerName "<token cliente>" -Category "<token categoria>"
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("encerramento", "aguardando_usuario", "visita_tecnica", "escalonamento")]
    [string]$TemplateName,

    [Parameter(Mandatory = $true)]
    [string]$IncidentId,

    [string]$CustomerName = "",

    [string]$Category = "",

    [string]$SignatureName = "Equipe de Suporte"
)

# Partes opcionais: só entram no texto se vierem preenchidas.
if ([string]::IsNullOrWhiteSpace($CustomerName)) {
    $greeting = "Olá,"
}
else {
    $greeting = "Olá, $CustomerName,"
}

if ([string]::IsNullOrWhiteSpace($Category)) {
    $categoryText = ""
}
else {
    $categoryText = " ($Category)"
}

# Modelos. Edite à vontade; o fechamento "@ precisa ficar no início da linha.
$templates = @{
    "encerramento" = @"
$greeting

O chamado $IncidentId$categoryText foi resolvido e será encerrado.
Se o problema voltar a acontecer, responda este e-mail informando o número do chamado.

Atenciosamente,
$SignatureName
"@

    "aguardando_usuario" = @"
$greeting

Para dar andamento ao chamado $IncidentId$categoryText, precisamos da seguinte informação:
- [descreva aqui o que falta]

Sem retorno em até 3 dias úteis, o chamado poderá ser encerrado.

Atenciosamente,
$SignatureName
"@

    "visita_tecnica" = @"
$greeting

O chamado $IncidentId$categoryText precisa de atendimento presencial.
Data e horário sugeridos: [preencha]
Local: [preencha]

Por favor, confirme se o horário funciona para você.

Atenciosamente,
$SignatureName
"@

    "escalonamento" = @"
$greeting

O chamado $IncidentId$categoryText foi encaminhado para a equipe responsável, que dará continuidade ao atendimento.
Você receberá as atualizações por este canal.

Atenciosamente,
$SignatureName
"@
}

$messageText = $templates[$TemplateName]

try {
    Set-Clipboard -Value $messageText
    Write-Output "Texto copiado para a área de transferência:"
}
catch {
    Write-Output "Não foi possível usar a área de transferência. Texto gerado:"
}

Write-Output ""
Write-Output $messageText
exit 0
