# ==============================================================================
# SOLID MASS DEPLOY v3 - GUI + RUNSPACES
# Improvements applied:
#   D - List<T> replaces array += (O(n) instead of O(n^2))
#   E - Cancel button with thread-safe token
#   F - Guard against empty target list
#   G - Configurable timeouts (normal and disruptive)
#   H - Summary statistics (SUCCESS/FAILED/SKIPPED/DISPATCHED/CANCELLED)
#   I - RichTextBox with per-result color coding
#   J - Progress bar + counter label
#   K - Console line limit (keeps last 1000 when over 1500)
#   L - Offer to open log file when deploy finishes
# ==============================================================================

$PastaDoScript = if ($MyInvocation.MyCommand.Path) { Split-Path $MyInvocation.MyCommand.Path } else { (Get-Location).Path }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not (Get-Module -ListAvailable -Name Posh-SSH)) {
    [System.Windows.Forms.MessageBox]::Show("Posh-SSH not found. Install: Install-Module Posh-SSH -Force", "Error", 0, 16)
    exit
}
Import-Module Posh-SSH -ErrorAction SilentlyContinue

# ==============================================================================
# HELPER (I + K) - Append a color-coded line to the RichTextBox.
# Colors: SUCCESS=Lime, FAILED=Red, SKIPPED=Yellow,
#         DISPATCHED=Orange, CANCELLED=Gray, header/other=White
# Line limit (K): when count exceeds 1500, top lines are trimmed to keep 1000.
# ==============================================================================
function Add-ConsoleLine {
    param([System.Windows.Forms.RichTextBox]$Rtb, [string]$Text)

    $color = switch -Regex ($Text) {
        '\[SUCCESS\]'    { [System.Drawing.Color]::Lime;         break }
        '\[FAILED\]'     { [System.Drawing.Color]::OrangeRed;    break }
        '\[SKIPPED\]'    { [System.Drawing.Color]::Yellow;       break }
        '\[DISPATCHED\]' { [System.Drawing.Color]::Orange;       break }
        '\[CANCELLED\]'  { [System.Drawing.Color]::DarkGray;     break }
        default          { [System.Drawing.Color]::WhiteSmoke           }
    }

    $Rtb.SelectionStart  = $Rtb.TextLength
    $Rtb.SelectionLength = 0
    $Rtb.SelectionColor  = $color
    $Rtb.AppendText("$Text`r`n")

    # K - trim top when over 1500 lines, keep last 1000
    if ($Rtb.Lines.Count -gt 1500) {
        $cutAt = $Rtb.GetFirstCharIndexFromLine($Rtb.Lines.Count - 1000)
        $Rtb.Select(0, $cutAt)
        $Rtb.SelectedText = ""
    }

    $Rtb.SelectionStart = $Rtb.TextLength
    $Rtb.ScrollToCaret()
}

# ==============================================================================
# UI - FORM
# ==============================================================================
$form = New-Object System.Windows.Forms.Form
$form.Text            = "Solid Mass Deploy v3 - Runspaces"
$form.Size            = New-Object System.Drawing.Size(570, 830)
$form.StartPosition   = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox     = $false

# ==============================================================================
# UI - COMMAND SOURCE GroupBox
# ==============================================================================
$grpSource      = New-Object System.Windows.Forms.GroupBox
$grpSource.Text = "Command Source"
$grpSource.Location = New-Object System.Drawing.Point(15, 10)
$grpSource.Size     = New-Object System.Drawing.Size(522, 200)
$form.Controls.Add($grpSource)

$rbInline          = New-Object System.Windows.Forms.RadioButton
$rbInline.Text     = "Inline Command"
$rbInline.Location = New-Object System.Drawing.Point(10, 22)
$rbInline.AutoSize = $true
$rbInline.Checked  = $true
$grpSource.Controls.Add($rbInline)

$rbFile          = New-Object System.Windows.Forms.RadioButton
$rbFile.Text     = "Script File (.sh or .ps1)"
$rbFile.Location = New-Object System.Drawing.Point(170, 22)
$rbFile.AutoSize = $true
$grpSource.Controls.Add($rbFile)

$txtCmd            = New-Object System.Windows.Forms.TextBox
$txtCmd.Multiline  = $true
$txtCmd.ScrollBars = "Vertical"
$txtCmd.Location   = New-Object System.Drawing.Point(10, 48)
$txtCmd.Size       = New-Object System.Drawing.Size(497, 125)
$txtCmd.Text       = ""
$grpSource.Controls.Add($txtCmd)

# Intercept Ctrl+V on the inline TextBox.
# Long commands pasted from terminals/documents often arrive with word-wrap
# line breaks in the middle of quoted expressions (e.g. inside sed '...').
# A newline inside a single-quoted bash argument acts as a command separator,
# causing "unterminated s command" errors in sed.
# Fix: replace each line break + any leading indent whitespace with one space,
# which reconstructs the original single-line command exactly as intended.
$txtCmd.Add_KeyDown({
    $e = $args[1]
    if ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::V) {
        $clip = [System.Windows.Forms.Clipboard]::GetText()
        if ($clip -match "`n") {
            $e.SuppressKeyPress = $true
            # \r?\n[ \t]* matches: optional CR + LF + any indent spaces/tabs
            # Replace the whole sequence with a single space to rejoin the line.
            $joined   = $clip -replace '\r?\n[ \t]*', ' '
            $joined   = $joined.Trim()
            $selStart = $txtCmd.SelectionStart
            $selLen   = $txtCmd.SelectionLength
            $txtCmd.Text = $txtCmd.Text.Remove($selStart, $selLen).Insert($selStart, $joined)
            $txtCmd.SelectionStart = $selStart + $joined.Length
        }
        # No line breaks: let WinForms handle the paste normally
    }
})

# Inline command hint: do NOT use sudo - the wrapper already applies it
$lblInlineHint           = New-Object System.Windows.Forms.Label
$lblInlineHint.Text      = "Do NOT use 'sudo' here - the script already wraps your command with sudo. Example: apt install curl"
$lblInlineHint.Location  = New-Object System.Drawing.Point(10, 178)
$lblInlineHint.Size      = New-Object System.Drawing.Size(497, 16)
$lblInlineHint.ForeColor = [System.Drawing.Color]::DarkOrange
$lblInlineHint.Font      = New-Object System.Drawing.Font("Microsoft Sans Serif", 7.5)
$grpSource.Controls.Add($lblInlineHint)

$txtScriptPath          = New-Object System.Windows.Forms.TextBox
$txtScriptPath.Location = New-Object System.Drawing.Point(10, 48)
$txtScriptPath.Size     = New-Object System.Drawing.Size(408, 22)
$txtScriptPath.ReadOnly = $true
$txtScriptPath.Visible  = $false
$grpSource.Controls.Add($txtScriptPath)

$btnBrowseScript          = New-Object System.Windows.Forms.Button
$btnBrowseScript.Location = New-Object System.Drawing.Point(425, 46)
$btnBrowseScript.Size     = New-Object System.Drawing.Size(80, 26)
$btnBrowseScript.Text     = "Browse"
$btnBrowseScript.Visible  = $false
$btnBrowseScript.Add_Click({
    $dlg        = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "Script Files (*.sh;*.ps1)|*.sh;*.ps1|All Files (*.*)|*.*"
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtScriptPath.Text = $dlg.FileName
    }
})
$grpSource.Controls.Add($btnBrowseScript)

$lblScriptHint           = New-Object System.Windows.Forms.Label
$lblScriptHint.Text      = "File read as raw bytes, Base64-encoded, decoded remotely.`r`n.sh via bash  |  .ps1 via pwsh (PowerShell Core required on target)"
$lblScriptHint.Location  = New-Object System.Drawing.Point(10, 80)
$lblScriptHint.Size      = New-Object System.Drawing.Size(497, 35)
$lblScriptHint.ForeColor = [System.Drawing.Color]::Gray
$lblScriptHint.Visible   = $false
$grpSource.Controls.Add($lblScriptHint)

$rbInline.Add_CheckedChanged({
    $on                      = $rbInline.Checked
    $txtCmd.Visible          = $on
    $txtScriptPath.Visible   = -not $on
    $btnBrowseScript.Visible = -not $on
    $lblScriptHint.Visible   = -not $on
})

# ==============================================================================
# UI - CREDENTIALS
# ==============================================================================
$lblUser          = New-Object System.Windows.Forms.Label
$lblUser.Text     = "SSH User:"
$lblUser.Location = New-Object System.Drawing.Point(15, 222)
$lblUser.AutoSize = $true
$form.Controls.Add($lblUser)

$txtUser          = New-Object System.Windows.Forms.TextBox
$txtUser.Location = New-Object System.Drawing.Point(15, 242)
$txtUser.Size     = New-Object System.Drawing.Size(240, 22)
$txtUser.Text     = ""
$form.Controls.Add($txtUser)

$lblPass          = New-Object System.Windows.Forms.Label
$lblPass.Text     = "SSH Password:"
$lblPass.Location = New-Object System.Drawing.Point(275, 222)
$lblPass.AutoSize = $true
$form.Controls.Add($lblPass)

$txtPass              = New-Object System.Windows.Forms.TextBox
$txtPass.Location     = New-Object System.Drawing.Point(275, 242)
$txtPass.Size         = New-Object System.Drawing.Size(262, 22)
$txtPass.PasswordChar = "*"
$txtPass.Text         = ""
$form.Controls.Add($txtPass)

# ==============================================================================
# UI - THREADS + DISRUPTIVE MODE
# ==============================================================================
$lblThreads          = New-Object System.Windows.Forms.Label
$lblThreads.Text     = "Simultaneous Threads:"
$lblThreads.Location = New-Object System.Drawing.Point(15, 276)
$lblThreads.AutoSize = $true
$form.Controls.Add($lblThreads)

$txtThreads          = New-Object System.Windows.Forms.TextBox
$txtThreads.Location = New-Object System.Drawing.Point(15, 296)
$txtThreads.Size     = New-Object System.Drawing.Size(100, 22)
$txtThreads.Text     = ""
$form.Controls.Add($txtThreads)

# ==============================================================================
# QUANDO USAR "DISRUPTIVE COMMAND":
#
# Marque esta opcao quando o comando vai DERRUBAR A CONEXAO SSH como
# consequencia natural da execucao. O servidor encerra o socket antes do
# Posh-SSH receber o codigo de saida, gerando falso [FAILED] sem esta opcao.
#
# DEVE marcar (comando derruba a conexao):
#   - reboot / shutdown -r
#   - update-grub && reboot
#   - systemctl restart networking / NetworkManager
#   - ifdown eth0 && ifup eth0
#   - apt upgrade com reboot automatico ao final
#   - iptables -F (flush de regras que permitiam o SSH)
#
# NAO marcar (modo normal, retorna exit code normalmente):
#   - update-grub (sem reboot)
#   - apt install <pacote>
#   - sed / echo / cp em arquivos
#   - systemctl restart apache2 (servico de aplicacao, nao afeta rede)
#   - Scripts .sh / .ps1 que nao reiniciem rede ou maquina
#
# REGRA PRATICA:
#   "O comando vai reiniciar a maquina ou a interface de rede?"
#     Sim -> marque Disruptive   (retorna [DISPATCHED] - sem output do comando)
#     Nao -> deixe desmarcado    (retorna [SUCCESS] ou [FAILED] com exit code)
#
# No modo Disruptive o payload roda via nohup em background - o SSH retorna
# imediatamente apos confirmar o dispatch, antes da acao destrutiva ocorrer.
# ==============================================================================
$chkDisruptive          = New-Object System.Windows.Forms.CheckBox
$chkDisruptive.Text     = "Disruptive Command (reboot / kernel update / network restart)"
$chkDisruptive.Location = New-Object System.Drawing.Point(130, 298)
$chkDisruptive.Size     = New-Object System.Drawing.Size(407, 20)
$chkDisruptive.ForeColor = [System.Drawing.Color]::DarkOrange
$form.Controls.Add($chkDisruptive)

# ==============================================================================
# UI - TIMEOUTS (G)
# Two independent fields: one for blocking commands, one for disruptive nohup.
# ==============================================================================
$lblTimeoutN          = New-Object System.Windows.Forms.Label
$lblTimeoutN.Text     = "Normal Timeout (s):"
$lblTimeoutN.Location = New-Object System.Drawing.Point(15, 330)
$lblTimeoutN.AutoSize = $true
$form.Controls.Add($lblTimeoutN)

$txtTimeoutN          = New-Object System.Windows.Forms.TextBox
$txtTimeoutN.Location = New-Object System.Drawing.Point(15, 350)
$txtTimeoutN.Size     = New-Object System.Drawing.Size(75, 22)
$txtTimeoutN.Text     = "120"
$form.Controls.Add($txtTimeoutN)

$lblTimeoutD          = New-Object System.Windows.Forms.Label
$lblTimeoutD.Text     = "Disruptive Timeout (s):"
$lblTimeoutD.Location = New-Object System.Drawing.Point(108, 330)
$lblTimeoutD.AutoSize = $true
$form.Controls.Add($lblTimeoutD)

$txtTimeoutD          = New-Object System.Windows.Forms.TextBox
$txtTimeoutD.Location = New-Object System.Drawing.Point(108, 350)
$txtTimeoutD.Size     = New-Object System.Drawing.Size(75, 22)
$txtTimeoutD.Text     = "30"
$form.Controls.Add($txtTimeoutD)

# ==============================================================================
# UI - TARGET LIST FILE
# ==============================================================================
$lblFile          = New-Object System.Windows.Forms.Label
$lblFile.Text     = "Target List File (TXT):"
$lblFile.Location = New-Object System.Drawing.Point(15, 384)
$lblFile.AutoSize = $true
$form.Controls.Add($lblFile)

$txtFile          = New-Object System.Windows.Forms.TextBox
$txtFile.Location = New-Object System.Drawing.Point(15, 404)
$txtFile.Size     = New-Object System.Drawing.Size(418, 22)
$form.Controls.Add($txtFile)

$btnBrowse          = New-Object System.Windows.Forms.Button
$btnBrowse.Location = New-Object System.Drawing.Point(442, 402)
$btnBrowse.Size     = New-Object System.Drawing.Size(95, 26)
$btnBrowse.Text     = "Browse"
$btnBrowse.Add_Click({
    $dlg        = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "Text Files (*.txt)|*.txt|All Files (*.*)|*.*"
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtFile.Text = $dlg.FileName
    }
})
$form.Controls.Add($btnBrowse)

# ==============================================================================
# UI - EXECUTION CONSOLE (I - RichTextBox with color support)
# ==============================================================================
$lblStatus          = New-Object System.Windows.Forms.Label
$lblStatus.Text     = "Execution Console:"
$lblStatus.Location = New-Object System.Drawing.Point(15, 440)
$lblStatus.AutoSize = $true
$form.Controls.Add($lblStatus)

$rtbConsole            = New-Object System.Windows.Forms.RichTextBox
$rtbConsole.ScrollBars = "Vertical"
$rtbConsole.Location  = New-Object System.Drawing.Point(15, 460)
$rtbConsole.Size      = New-Object System.Drawing.Size(522, 210)
$rtbConsole.ReadOnly  = $true
$rtbConsole.BackColor = [System.Drawing.Color]::Black
$rtbConsole.ForeColor = [System.Drawing.Color]::WhiteSmoke
$rtbConsole.Font      = New-Object System.Drawing.Font("Consolas", 9)
$rtbConsole.WordWrap  = $false
$form.Controls.Add($rtbConsole)

# ==============================================================================
# UI - PROGRESS BAR (J)
# ==============================================================================
$progressBar          = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(15, 678)
$progressBar.Size     = New-Object System.Drawing.Size(522, 18)
$progressBar.Minimum  = 0
$progressBar.Maximum  = 100
$progressBar.Value    = 0
$form.Controls.Add($progressBar)

$lblProgress           = New-Object System.Windows.Forms.Label
$lblProgress.Text      = "Ready"
$lblProgress.Location  = New-Object System.Drawing.Point(15, 700)
$lblProgress.Size      = New-Object System.Drawing.Size(522, 18)
$lblProgress.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$lblProgress.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($lblProgress)

# ==============================================================================
# UI - START + CANCEL BUTTONS (E)
# ==============================================================================
$btnRun           = New-Object System.Windows.Forms.Button
$btnRun.Location  = New-Object System.Drawing.Point(120, 726)
$btnRun.Size      = New-Object System.Drawing.Size(160, 44)
$btnRun.Text      = "START DEPLOY"
$btnRun.Font      = New-Object System.Drawing.Font("Microsoft Sans Serif", 10, [System.Drawing.FontStyle]::Bold)
$btnRun.BackColor = [System.Drawing.Color]::DarkGreen
$btnRun.ForeColor = [System.Drawing.Color]::White

# E - Cancel button signals the shared token; runspaces check it at each gate
$btnCancel           = New-Object System.Windows.Forms.Button
$btnCancel.Location  = New-Object System.Drawing.Point(298, 726)
$btnCancel.Size      = New-Object System.Drawing.Size(140, 44)
$btnCancel.Text      = "CANCEL"
$btnCancel.Font      = New-Object System.Drawing.Font("Microsoft Sans Serif", 10, [System.Drawing.FontStyle]::Bold)
$btnCancel.BackColor = [System.Drawing.Color]::DarkRed
$btnCancel.ForeColor = [System.Drawing.Color]::White
$btnCancel.Enabled   = $false
$form.Controls.Add($btnRun)
$form.Controls.Add($btnCancel)

# E - Thread-safe cancel token: a synchronized hashtable shared between
#     the UI thread and all runspace threads.
#     Hashtable read/write is atomic for bool values - no lock needed.
$cancelToken = [hashtable]::Synchronized(@{ Requested = $false })

$btnCancel.Add_Click({
    $cancelToken.Requested = $true
    $btnCancel.Enabled     = $false
    $btnCancel.Text        = "Cancelling..."
    $lblProgress.ForeColor = [System.Drawing.Color]::DarkOrange
    $lblProgress.Text      = "Cancellation requested - waiting for active threads..."
})

# ==============================================================================
# RUNSPACE SCRIPTBLOCK
#
# Parameters (positional, in order):
#   [string]    $OriginalLine       - raw line from TXT (hostname + IP)
#   [string]    $Command            - inline command; empty in file mode
#   [string]    $User               - SSH username
#   [string]    $SenhaSSH           - SSH password (plain; SecureString built here)
#   [string]    $ScriptB64          - Base64 file content; empty in inline mode
#   [string]    $ScriptType         - "sh" | "ps1" | "" (inline)
#   [bool]      $IsDisruptive       - true = fire-and-forget via nohup
#   [hashtable] $CancelToken        - shared cancel flag (E)
#   [int]       $TimeoutNormal      - SSH timeout for blocking commands (G)
#   [int]       $TimeoutDisruptive  - SSH timeout for dispatched commands (G)
# ==============================================================================
$scriptBlock = {
    param(
        [string]    $OriginalLine,
        [string]    $Command,
        [string]    $User,
        [string]    $SenhaSSH,
        [string]    $ScriptB64,
        [string]    $ScriptType,
        [bool]      $IsDisruptive,
        [hashtable] $CancelToken,
        [int]       $TimeoutNormal,
        [int]       $TimeoutDisruptive
    )

    # E - cancel gate 1: skip entirely if cancelled before we even start
    if ($CancelToken.Requested) { return "$OriginalLine ; [CANCELLED] Deploy aborted" }

    $ipMatch = [regex]::Match($OriginalLine, '\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b')
    if (-not $ipMatch.Success) { return "$OriginalLine ; [SKIPPED] Invalid IP Format" }
    $ip = $ipMatch.Value

    # E - cancel gate 2: after IP parse, before network I/O
    if ($CancelToken.Requested) { return "$OriginalLine ; [CANCELLED] Deploy aborted" }

    $ping = New-Object System.Net.NetworkInformation.Ping
    try {
        if ($ping.Send($ip, 1500).Status -ne 'Success') { return "$OriginalLine ; [SKIPPED] No Ping" }
    } catch { return "$OriginalLine ; [SKIPPED] No Ping" }

    # E - cancel gate 3: after ping, before SSH handshake
    if ($CancelToken.Requested) { return "$OriginalLine ; [CANCELLED] Deploy aborted" }

    # PSScriptAnalyzer suppress: plaintext is unavoidable - password comes from WinForms TextBox
    $secPass    = ConvertTo-SecureString $SenhaSSH -AsPlainText -Force  #NOSONAR
    $credential = New-Object System.Management.Automation.PSCredential ($User, $secPass)
    $shellPass  = $SenhaSSH -replace "'", "'\''"

    $session = $null
    for ($i = 0; $i -lt 2; $i++) {
        # E - cancel gate 4: inside retry loop
        if ($CancelToken.Requested) { return "$OriginalLine ; [CANCELLED] Deploy aborted" }
        try {
            $session = New-SSHSession -ComputerName $ip -Credential $credential -AcceptKey -ErrorAction Stop
            if ($session -and $session.Connected) { break }
        } catch {
            if ($null -ne $session) {
                Remove-SSHSession -SSHSession $session -ErrorAction SilentlyContinue | Out-Null
                $session = $null
            }
            Start-Sleep -Milliseconds 200
        }
    }

    if (-not ($session -and $session.Connected)) {
        return "$OriginalLine ; [FAILED] SSH Connection Failed"
    }

    try {
        # --- Payload construction (Base64 safe tunnel) ---
        if ($ScriptType -eq 'sh') {
            $payloadB64 = $ScriptB64
            $runner     = "bash"
        }
        elseif ($ScriptType -eq 'ps1') {
            $payloadB64 = $ScriptB64
            $runner     = "pwsh -NonInteractive -NoProfile -Command -"
        }
        else {
            # Normalize line endings before encoding: Windows TextBox produces CRLF (\r\n).
            # If sent as-is, bash receives "command\r" and sudo sees "command\r: not found".
            $cmdNormalized = $Command.Replace("`r`n", "`n").Replace("`r", "`n").Trim()
            $payloadB64    = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($cmdNormalized))
            $runner        = "bash"
        }

        $coreCmd = "echo $payloadB64 | base64 -d | $runner"

        if ($IsDisruptive) {
            # G - use configurable disruptive timeout
            $timestamp   = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $logFile     = "/tmp/.deploy_${ip}_${timestamp}.log"
            $SafeCommand = "echo '$shellPass' | sudo -S -p '' bash -c 'export DEBIAN_FRONTEND=noninteractive; nohup bash -c ""$coreCmd"" >$logFile 2>&1 & disown; echo DISPATCHED'"
            $result      = Invoke-SSHCommand -SSHSession $session -Command $SafeCommand -Timeout $TimeoutDisruptive -ErrorAction Stop

            if ($result.Output -match 'DISPATCHED') {
                $logReturn = "$OriginalLine ; [DISPATCHED] Fire-and-forget sent - log: $logFile"
            } else {
                $outText = ($result.Output | Where-Object { $_ }) -join ' | '
                $errText = ($result.Error  | Where-Object { $_ }) -join ' | '
                $detail  = @()
                if ($outText) { $detail += "OUT: $outText" }
                if ($errText) { $detail += "ERR: $errText" }
                $detailStr = if ($detail) { " >> $($detail -join ' ')" } else { "" }
                $logReturn = "$OriginalLine ; [FAILED] Could not dispatch (Exit: $($result.ExitStatus))$detailStr"
            }
        }
        else {
            # G - use configurable normal timeout
            $SafeCommand = "echo '$shellPass' | sudo -S -p '' bash -c 'export DEBIAN_FRONTEND=noninteractive; $coreCmd'"
            $result      = Invoke-SSHCommand -SSHSession $session -Command $SafeCommand -Timeout $TimeoutNormal -ErrorAction Stop

            if ($result.ExitStatus -eq 0) {
                $logReturn = "$OriginalLine ; [SUCCESS] Script Applied"
            } else {
                # Include stdout and stderr so the operator can diagnose the root cause
                # without needing to SSH manually into the server
                $outText = ($result.Output | Where-Object { $_ }) -join ' | '
                $errText = ($result.Error  | Where-Object { $_ }) -join ' | '
                $detail  = @()
                if ($outText) { $detail += "OUT: $outText" }
                if ($errText) { $detail += "ERR: $errText" }
                $detailStr = if ($detail) { " >> $($detail -join ' ')" } else { "" }
                $logReturn = "$OriginalLine ; [FAILED] Linux Error (Exit: $($result.ExitStatus))$detailStr"
            }
        }
    }
    catch {
        return "$OriginalLine ; [FAILED] Timeout or Execution Drop: $($_.Exception.Message)"
    }
    finally {
        Remove-SSHSession -SSHSession $session -ErrorAction SilentlyContinue | Out-Null
    }

    return $logReturn
}

# ==============================================================================
# START DEPLOY - BUTTON CLICK HANDLER
# ==============================================================================
$btnRun.Add_Click({

    # --- Validate: target list file ---
    $listPath = $txtFile.Text
    if ([string]::IsNullOrWhiteSpace($listPath) -or -not (Test-Path $listPath)) {
        [System.Windows.Forms.MessageBox]::Show("Please select a valid TXT file.", "Error", 0, 16)
        return
    }

    # --- Validate: thread count ---
    $maxThreads = 0
    if (-not [int]::TryParse($txtThreads.Text, [ref]$maxThreads) -or $maxThreads -lt 1) {
        [System.Windows.Forms.MessageBox]::Show("Invalid thread count. Must be a positive integer.", "Error", 0, 16)
        return
    }

    # --- Validate: credentials ---
    if ([string]::IsNullOrWhiteSpace($txtUser.Text)) {
        [System.Windows.Forms.MessageBox]::Show("SSH User cannot be empty.", "Error", 0, 16)
        return
    }
    if ([string]::IsNullOrWhiteSpace($txtPass.Text)) {
        [System.Windows.Forms.MessageBox]::Show("SSH Password cannot be empty.", "Error", 0, 16)
        return
    }

    # G - Validate: timeouts
    $timeoutNormal = 0; $timeoutDisruptive = 0
    if (-not [int]::TryParse($txtTimeoutN.Text, [ref]$timeoutNormal) -or $timeoutNormal -lt 5) {
        [System.Windows.Forms.MessageBox]::Show("Normal Timeout must be >= 5 seconds.", "Error", 0, 16)
        return
    }
    if (-not [int]::TryParse($txtTimeoutD.Text, [ref]$timeoutDisruptive) -or $timeoutDisruptive -lt 5) {
        [System.Windows.Forms.MessageBox]::Show("Disruptive Timeout must be >= 5 seconds.", "Error", 0, 16)
        return
    }

    # --- Resolve payload (inline or file) ---
    $cmdExec = ""; $scriptB64 = ""; $scriptType = ""

    if ($rbFile.Checked) {
        $scriptPath = $txtScriptPath.Text
        if ([string]::IsNullOrWhiteSpace($scriptPath) -or -not (Test-Path $scriptPath)) {
            [System.Windows.Forms.MessageBox]::Show("Please select a valid script file (.sh or .ps1).", "Error", 0, 16)
            return
        }
        $ext = [System.IO.Path]::GetExtension($scriptPath).ToLower().TrimStart('.')
        if ($ext -notin @('sh', 'ps1')) {
            [System.Windows.Forms.MessageBox]::Show("Unsupported file type. Use .sh or .ps1.", "Error", 0, 16)
            return
        }
        $rawBytes  = [System.IO.File]::ReadAllBytes($scriptPath)
        $scriptB64 = [System.Convert]::ToBase64String($rawBytes)
        $scriptType = $ext
        if ($scriptB64.Length -gt 65000) {
            $ans = [System.Windows.Forms.MessageBox]::Show(
                "Script Base64 is $($scriptB64.Length) chars. May exceed SSH limits on some servers. Continue?",
                "Warning", 4, 48)
            if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }
    }
    else {
        $cmdExec = $txtCmd.Text
        if ([string]::IsNullOrWhiteSpace($cmdExec)) {
            [System.Windows.Forms.MessageBox]::Show("Please enter a command to execute.", "Error", 0, 16)
            return
        }

        # Detect newlines inside a single-quoted region (e.g. sed '...multiline...').
        # In bash/sed, a newline inside single quotes acts as a command separator,
        # breaking commands like sed s/// that must stay on one line.
        # Example symptom: sed reports "unterminated s command" at the $ before the break.
        if ($cmdExec -match "`n") {
            $singleQuoteCount = ($cmdExec -split "'" ).Count - 1
            $hasOpenQuote     = ($singleQuoteCount % 2) -ne 0
            if ($hasOpenQuote) {
                $ans = [System.Windows.Forms.MessageBox]::Show(
                    "WARNING: The command contains line breaks inside a single-quoted string (e.g. a sed expression).`r`n`r`nThis will cause the remote shell to split the command mid-expression, producing errors like:`r`n  sed: unterminated 's' command`r`n`r`nPaste the command as a single line with no Enter presses inside quoted regions.`r`n`r`nContinue anyway?",
                    "Possible Multiline Issue Detected", 4, 48)
                if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            }
        }
    }

    $targets      = @(Get-Content $listPath -Encoding UTF8 | Where-Object { $_.Trim() -ne "" })
    $totalTargets = $targets.Count

    # F - guard: empty target list after filtering blank lines
    if ($totalTargets -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("The target file contains no valid entries.", "Error", 0, 16)
        return
    }

    $isDisruptive  = $chkDisruptive.Checked
    $usr           = $txtUser.Text
    $senhaDigitada = $txtPass.Text
    $logPath       = Join-Path $PastaDoScript "Log_Deploy_Solid_$((Get-Date).ToString('yyyyMMdd_HHmmss')).txt"

    # E - reset cancel token before each run
    $cancelToken.Requested = $false

    # UI: switch to running state
    $btnRun.Enabled    = $false
    $btnCancel.Enabled = $true
    $btnCancel.Text    = "CANCEL"
    $progressBar.Value = 0
    $lblProgress.Text  = "0 / $totalTargets"
    $lblProgress.ForeColor = [System.Drawing.Color]::DimGray
    $rtbConsole.Clear()

    Add-ConsoleLine $rtbConsole "=== Starting deploy for $totalTargets machines ==="
    if ($isDisruptive) {
        Add-ConsoleLine $rtbConsole "[!] DISRUPTIVE MODE - commands dispatched via nohup (fire-and-forget)"
    }
    Add-ConsoleLine $rtbConsole "Log: $logPath"
    Add-ConsoleLine $rtbConsole ""
    [System.Windows.Forms.Application]::DoEvents()

    # H - summary counters (incremented in polling loop, displayed at end)
    $stats = @{ Success = 0; Failed = 0; Skipped = 0; Dispatched = 0; Cancelled = 0 }

    $utf8NoBom     = New-Object System.Text.UTF8Encoding($false)
    $writer        = $null
    $runspacePool  = $null
    $deploySuccess = $false
    $summaryLine   = ""

    try {
        $writer = [System.IO.StreamWriter]::new($logPath, $false, $utf8NoBom)

        $initialState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $initialState.ImportPSModule('Posh-SSH')

        $runspacePool = [runspacefactory]::CreateRunspacePool(1, $maxThreads, $initialState, $Host)
        $runspacePool.Open()

        # D - List<T>: O(1) Add vs O(n) copy on every += with a fixed array
        $jobs = [System.Collections.Generic.List[object]]::new()
        foreach ($target in $targets) {
            $ps              = [powershell]::Create()
            $ps.RunspacePool = $runspacePool
            $null = $ps.AddScript($scriptBlock).AddArgument($target).AddArgument($cmdExec).AddArgument($usr).AddArgument($senhaDigitada).AddArgument($scriptB64).AddArgument($scriptType).AddArgument($isDisruptive).AddArgument($cancelToken).AddArgument($timeoutNormal).AddArgument($timeoutDisruptive)
            $jobs.Add([PSCustomObject]@{
                PowerShell    = $ps
                Handle        = $ps.BeginInvoke()
                Processed     = $false
                LinhaOriginal = $target
            })
        }

        $completed = 0
        while ($completed -lt $totalTargets) {
            foreach ($job in $jobs) {
                if ($job.Handle.IsCompleted -and -not $job.Processed) {
                    try {
                        $rawResult = $job.PowerShell.EndInvoke($job.Handle)
                        if ($rawResult) {
                            $resultLog = ($rawResult | Out-String).Trim()
                            $writer.WriteLine($resultLog)
                            $writer.Flush()
                            Add-ConsoleLine $rtbConsole $resultLog

                            # H - tally result type for summary
                            switch -Regex ($resultLog) {
                                '\[SUCCESS\]'    { $stats.Success++;    break }
                                '\[FAILED\]'     { $stats.Failed++;     break }
                                '\[SKIPPED\]'    { $stats.Skipped++;    break }
                                '\[DISPATCHED\]' { $stats.Dispatched++; break }
                                '\[CANCELLED\]'  { $stats.Cancelled++;  break }
                            }
                        }
                    }
                    catch {
                        $err = "$($job.LinhaOriginal) ; [FAILED] Thread Internal Error: $_"
                        $writer.WriteLine($err)
                        $writer.Flush()
                        Add-ConsoleLine $rtbConsole $err
                        $stats.Failed++
                    }
                    finally {
                        $job.PowerShell.Dispose()
                        $job.Processed = $true
                        $completed++

                        # J - update progress bar and label after each result
                        $progressBar.Value = [int](($completed / $totalTargets) * 100)
                        $lblProgress.Text  = "$completed / $totalTargets"
                    }
                }
            }
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 50
        }

        # H - build summary line and write to log while writer is still open
        $summaryLine = "SUCCESS: $($stats.Success)  |  FAILED: $($stats.Failed)  |  SKIPPED: $($stats.Skipped)  |  DISPATCHED: $($stats.Dispatched)  |  CANCELLED: $($stats.Cancelled)"
        $writer.WriteLine("")
        $writer.WriteLine("=== DEPLOY COMPLETED === $summaryLine")
        $writer.Flush()
        $deploySuccess = $true

    }
    catch {
        Add-ConsoleLine $rtbConsole "[GLOBAL CRITICAL ERROR] $_"
    }
    finally {
        if ($null -ne $writer)       { $writer.Dispose() }
        if ($null -ne $runspacePool) { $runspacePool.Close(); $runspacePool.Dispose() }
    }

    # --- Post-deploy UI update ---
    Add-ConsoleLine $rtbConsole ""
    if ($deploySuccess) {
        $label = if ($stats.Cancelled -gt 0) { "DEPLOY PARTIALLY COMPLETED" } else { "DEPLOY COMPLETED" }
        Add-ConsoleLine $rtbConsole "=== $label === $summaryLine"
        $lblProgress.Text      = $summaryLine
        $lblProgress.ForeColor = [System.Drawing.Color]::DarkGreen
    }
    else {
        Add-ConsoleLine $rtbConsole "=== DEPLOY ABORTED DUE TO CRITICAL ERROR ==="
        $lblProgress.Text      = "Aborted - check console for details"
        $lblProgress.ForeColor = [System.Drawing.Color]::OrangeRed
    }
    $progressBar.Value = 100

    # Restore UI
    $btnRun.Enabled    = $true
    $btnCancel.Enabled = $false
    $btnCancel.Text    = "CANCEL"

    # L - offer to open log file when deploy finishes (success or partial)
    if ($deploySuccess) {
        $msg = "Deploy finished.`r`n`r`n$summaryLine`r`n`r`nOpen log file?"
        $ans = [System.Windows.Forms.MessageBox]::Show($msg, "Deploy Complete", 4, 64)
        if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) { Invoke-Item $logPath }
    }
})

# Bug fix: block window close while a deploy is running.
# Without this, closing the form returns ShowDialog() but the Runspaces keep
# executing invisibly in the background until all jobs finish naturally.
$form.Add_FormClosing({
    # $args[0] = sender (Form), $args[1] = FormClosingEventArgs
    # Avoid declaring $sender: it is an automatic variable and would trigger PSScriptAnalyzer
    $e = $args[1]
    if (-not $btnRun.Enabled) {
        $e.Cancel = $true
        [System.Windows.Forms.MessageBox]::Show(
            "A deploy is currently running.`r`nClick CANCEL to stop it first, then close the window.",
            "Deploy in Progress", 0, 48)
    }
})

[void]$form.ShowDialog()
