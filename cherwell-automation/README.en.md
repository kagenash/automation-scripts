🇧🇷 [Português](README.md) | 🇺🇸 **English**

# cherwell-automation

> ⚠️ **For testing and study only.** These scripts are generic and meant for learning and experimenting with Cherwell integrations. They are not production-ready tools: review, adapt and test them in your own environment before any real use.

PowerShell automation kit for Cherwell Service Management (CSM): weekly ticket report, reply templates, host check and REST API export. The scripts are called from One-Step Actions (**Run a Program** action) or run on their own from an exported CSV.

## What it does

| Script | Purpose |
|---|---|
| [`cherwell-bridge-test.ps1`](cherwell-bridge-test.ps1) | Writes a log line with the ticket ID — proves that "Run a Program" can call external scripts |
| [`cherwell-host-check.ps1`](cherwell-host-check.ps1) | Ping or TCP port test; returns the result as an exit code so the One-Step can decide the next action |
| [`cherwell-reply-template.ps1`](cherwell-reply-template.ps1) | Builds a standard reply (closure, waiting on user, on-site visit, escalation) and copies it to the clipboard |
| [`cherwell-weekly-report.ps1`](cherwell-weekly-report.ps1) | Reads the CSV of a saved search, calculates the week's metrics, generates HTML and drafts the e-mail in Outlook |
| [`cherwell-api-export.ps1`](cherwell-api-export.ps1) | OAuth2 login, paged search on the REST API and CSV export in the format the report expects |

Weekly report metrics:

1. Opened and closed in the period, and the balance between them
2. Current backlog and aged backlog (open for more than N days)
3. Resolution time — average and median, in hours
4. Breakdowns by category, technician and status
5. Attached CSV with the full aged backlog

> The generated report, reply templates and log messages are in Brazilian Portuguese. Edit the strings in the scripts to change the language.

## Requirements

- Windows PowerShell 5.1+ or PowerShell 7+
- Outlook installed — only for sending e-mail
- REST API Client ID (CSM Administrator → Security → Edit REST API client settings) — only for `cherwell-api-export.ps1`

## Usage

Test with the sample data (60 fictitious tickets):

```powershell
.\cherwell-weekly-report.ps1 -InputPath .\exemplos\incidentes_exemplo.csv -ReferenceDate 2026-11-23
.\cherwell-reply-template.ps1 -TemplateName encerramento -IncidentId "INC-101234" -CustomerName "Maria Silva" -Category "Impressora"
.\cherwell-host-check.ps1 -HostName "localhost"; $LASTEXITCODE
.\cherwell-bridge-test.ps1 -IncidentId "INC-TESTE" -LogPath ".\saida\ponte.log"
```

Expected report result with the sample data:

| Metric | Value |
|---|---|
| Opened in the period | 13 |
| Closed in the period | 5 |
| Balance | -8 |
| Current backlog | 28 |
| Backlog > 7 days | 18 |
| Average resolution time (h) | 77.5 |
| Median resolution time (h) | 84.8 |

The HTML is saved to `saida\relatorio_semanal_2026-11-23.html`.

Called from Cherwell (One-Step → Run a Program):

```
Program:   powershell.exe
Arguments: -NoProfile -ExecutionPolicy Bypass -File "C:\scripts\cherwell-host-check.ps1" -HostName "<host token>"
```

Check **Store Exit Code from Program** and use the code in the next action's condition.

Export made from the Cherwell UI (columns with display names):

```powershell
.\cherwell-weekly-report.ps1 -InputPath "C:\scripts\exports" `
    -IdColumn "Incident ID" -OwnerColumn "Owned By" `
    -CreatedColumn "Created Date Time" -ClosedColumn "Closed Date Time" `
    -DateCulture "pt-BR"
```

If a column is missing, the script lists the ones in the file. For e-mail, `-SendEmail -To "manager@company.com"` opens the message for review; `-SendNow` sends it right away.

Via REST API:

```powershell
.\cherwell-api-export.ps1 -SaveCredential
.\cherwell-api-export.ps1 -ServerUrl "https://cherwell.company.local" -ClientId "<client id>" -OutputCsv ".\exports\api.csv"
.\cherwell-weekly-report.ps1 -InputPath ".\exports\api.csv" -DateCulture "en-US"
```

## Exit codes

| Code | bridge-test | reply-template | host-check | weekly-report / api-export |
|---|---|---|---|---|
| 0 | Log written | OK | Online | OK |
| 1 | — | — | Offline | No records |
| 2 | Failed to write the log | — | Error (DNS) | Error |

## Notes

- The `.ps1` files are **UTF-8 with BOM** — without the BOM, Windows PowerShell 5.1 breaks the accented characters in the generated text
- The e-mail opens for review by default; use `-SendNow` only after validating the content
- In Scheduled Items the One-Step runs on the server, so "Run a Program" can't see scripts on the local machine
- Each REST API login uses a CSM license; the script logs out at the end
- If the `-MaxPages` limit is reached, `cherwell-api-export.ps1` warns that the export is incomplete
- On API errors the script also prints Cherwell's response (on 5.1 the exception alone only says "(400) Bad Request")
- The API credential is saved with `Export-Clixml` (DPAPI encryption only on Windows, tied to the user)
- The scripts are generic, meant for testing — adjust paths, tokens and fields to your environment
- The data in `exemplos/` is fictitious

## License

MIT — see [LICENSE](LICENSE).
