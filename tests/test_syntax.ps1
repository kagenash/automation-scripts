<#
Valida a sintaxe de todos os scripts do repositório sem executá-los:
- .ps1 -> parseados via AST do próprio PowerShell (sem dependências externas)
- .sh  -> validados com `bash -n` (checagem de sintaxe, sem execução)
#>

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$failures = @()

Get-ChildItem -Path $root -Recurse -Filter *.ps1 | Where-Object { $_.FullName -notlike "*\tests\*" } | ForEach-Object {
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        $failures += "$($_.FullName): $($errors -join '; ')"
    } else {
        Write-Host "OK  $($_.FullName)" -ForegroundColor Green
    }
}

$bash = Get-Command bash -ErrorAction SilentlyContinue
if (-not $bash) {
    $gitBash = "C:\Program Files\Git\bin\bash.exe"
    if (Test-Path $gitBash) { $bash = $gitBash }
}

if ($bash) {
    Get-ChildItem -Path $root -Recurse -Filter *.sh | ForEach-Object {
        & $bash -n $_.FullName 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $failures += "$($_.FullName): erro de sintaxe (bash -n)"
        } else {
            Write-Host "OK  $($_.FullName)" -ForegroundColor Green
        }
    }
} else {
    Write-Warning "bash não encontrado no PATH — pulando validação dos scripts .sh"
}

if ($failures.Count -gt 0) {
    Write-Host "`nFalhas de sintaxe:" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    exit 1
}

Write-Host "`nTodos os scripts têm sintaxe válida." -ForegroundColor Cyan
