<p align="center">
  <img src="assets/resiliency-triage-banner.svg" alt="Resiliency Review Buddy" width="100%">
</p>

# Resiliency Review Buddy

> [!IMPORTANT]
> **Requirements**
> - **PowerShell 7.2 or later** (`pwsh`). Windows PowerShell 5.1 is **not** supported. Install: `winget install Microsoft.PowerShell`
> - **Az.Accounts** module for sign-in and tokens: `Install-Module Az.Accounts -Scope CurrentUser` (the tool offers to install it if missing)
> - **ThreadJob** module for background updates (included with PowerShell 7)
> - A terminal with ANSI/VT and UTF-8 support, a wide window works best, e.g. 120+ columns (Windows Terminal recommended)
> - Azure RBAC: **Reader** to view reviews. To change statuses you need write access to `Microsoft.Advisor/recommendations`, for example **Advisor Recommendations Contributor** or **Contributor**.
> - Network access to `management.azure.com` (Advisor and Resource Graph REST APIs; no other Az modules needed). Behind a corporate proxy the tool authenticates with your Windows user automatically (see [Proxy](#proxy)).

A PowerShell TUI (text user interface) for the **resiliency reviews** your Microsoft account team shares with you in [Azure Advisor](https://learn.microsoft.com/azure/advisor/advisor-resiliency-reviews). With it you can:

- track the progress of one, several or all reviews at once,
- export the recommendations as a CSV to import into a task planner,
- triage recommendations quickly by setting **Postponed**, **Completed** or **Dismissed** on *every* impacted resource in one step, with the update running in the background.

## Features

| Step | What happens |
|------|--------------|
| **Sign-in** | Finds an existing `Az` context, shows the account and tenant, and asks if you want to reuse it. Otherwise it runs `Connect-AzAccount` (browser or `-UseDeviceAuthentication`). |
| **Review selection** | Lists every resiliency review you can see (see [Review discovery](#review-discovery)), with the number of affected resources. Pick reviews with checkboxes (`Space` toggles one, `A` toggles all). The resource count is the number of unique resources (older duplicate items are counted once). |
| **Progress overview** | Stacked progress bar with counts for the selected reviews and for each review. Counts are shown per recommendation and per resource: **Active** (Not started + In progress), **Postponed**, **Completed** and **Dismissed** (formerly *Rejected*). |
| **Export** | Writes a task-planner CSV of all recommendations, or only the priorities you select. You can export only *Active* work or all statuses. |
| **Triage** | Lists **all recommendations** of the selected reviews, sorted Critical → High → Medium → Low. Typing searches the **recommendation titles** live. Each row shows the title, number of affected resources, the **review** it comes from, a short description and the current status. A recommendation that appears in several reviews is listed **once**, under the most recent review (by publish date), and shown as `(+n) Review name`. A status change applies to its resources in **all** of those reviews. The affected resources are loaded only when you pick a status or **Details**. |
| **Change status** | `Enter` on a recommendation opens the status picker. It shows the current status and switches **all affected resources** to **Completed**, **Postponed** or **Dismissed**. Dismiss asks for a reason; Postpone asks for a date. A details view (description, benefits, notes, resources) is one option away. |
| **Activity log** | Writes every step and REST call to `exports\logs\session-*.log`. When loading takes more than 15 seconds, the latest activity appears under the spinner. |
| **Background update** | The update runs as a background thread job, so you can keep triaging. Every resource is **re-read after the update** and the live status decides the result, so an API error on a change that Azure applied anyway still counts as a success. The TUI reports how many resources were **verified** and how many **failed**. Deleted resources are skipped. Details go to `exports\logs\update-*.csv`. |

## Prerequisites

- PowerShell **7.2+** in a real terminal (Windows Terminal recommended)
- `Az.Accounts` module: `Install-Module Az.Accounts -Scope CurrentUser`
- `ThreadJob` module (ships with PowerShell 7)
- RBAC: **Reader** to view reviews. To change statuses you need write access to `Microsoft.Advisor/recommendations` (e.g. **Advisor Recommendations Contributor**, **Contributor**).

## Usage

```powershell
git clone https://github.com/chrochma/ResiliencyReviewBuddy.git
cd .\ResiliencyReviewBuddy

# Interactive: reuse or create an Azure sign-in, then pick reviews
.\Start-ResiliencyTriage.ps1

# Specific tenant / subscriptions
.\Start-ResiliencyTriage.ps1 -TenantId contoso.onmicrosoft.com -SubscriptionId <subId1>,<subId2>

# Try it without Azure (fictional data, simulated updates incl. failures)
.\Start-ResiliencyTriage.ps1 -Demo
```

| Parameter | Description |
|-----------|-------------|
| `-TenantId` | Tenant for a new sign-in |
| `-SubscriptionId` | Only scan these subscriptions (default: all except Disabled / Deleted) |
| `-UseDeviceAuthentication` | Device code sign-in |
| `-ExportPath` | Folder for CSV exports and failure logs (default `.\exports`) |
| `-Demo` | Offline demo mode |
| `-Proxy` | Proxy URL, when the system proxy is not the right one (default: system proxy incl. PAC) |
| `-ProxyCredential` | Explicit proxy credential when your Windows user is not accepted |
| `-LargeLoadThreshold` | Number of resources above which loading the resource list asks for confirmation (default 10000) |

### Review discovery

Reviews are collected from three sources, so none is missed:

1. **ARM list** per subscription (parallel, network errors and timeouts are retried).
2. **Resource Graph** `microsoft.advisor/resiliencyreviews` across all subscriptions.
3. **Review references on recommendations.** A review resource can sit in a subscription you cannot read while its recommendations sit in subscriptions you can. Such reviews are listed with status `Unknown` and can be triaged normally.

Subscriptions that could not be read are counted on the selection screen and listed in the activity log.

### Counts first, resources on demand

Reviews can hold hundreds of thousands of resource items. The tool therefore loads only **counts per recommendation and status**, aggregated server-side in Resource Graph. All reviews of a tenant load in a few seconds, even a review with 200,000+ resources.

The list of affected resources is fetched only for the recommendation you act on: when you pick a status or **Details** in triage, or when you include resource IDs in an export. Above `-LargeLoadThreshold` resources (default 10,000) the tool asks first; Resource Graph returns about 1,000 resources every 4 seconds.

Resource Graph can lag a few minutes behind Advisor, and brand-new Advisor items may not be listed yet. Status updates are always verified live per resource, and the verified statuses are kept for the session, so a reload does not show stale data for recommendations you just changed.

### Activity log

Every run writes an activity log to `exports\logs\session-<timestamp>.log`. It lists each step (sign-in, subscription scan, Resource Graph, Advisor reads, status updates) and every REST call with its status code and duration. Tokens and request bodies are never logged. If a loading step takes **longer than 15 seconds**, the spinner screen also shows the latest log lines and the path of the log file, so you can see what the tool is waiting for.

### Proxy

PowerShell 7 uses the system proxy but does not log on to it, which ends in `HTTP 407 Proxy Authentication Required`. The tool therefore sets the process-wide proxy credentials to your **signed-in Windows user** (Kerberos / NTLM via `Negotiate`) before the first web call. This covers sign-in, the Advisor and Resource Graph calls and the background update jobs. The start screen shows the detected proxy.

```powershell
# Use a specific proxy (still authenticated as your Windows user)
.\Start-ResiliencyTriage.ps1 -Proxy http://proxy.contoso.com:8080

# Proxy wants a different account (e.g. Basic auth)
.\Start-ResiliencyTriage.ps1 -ProxyCredential (Get-Credential)
```

### Keys

| Where | Keys |
|-------|------|
| Menus | `↑` `↓` `Enter`, `1-9` quick select, `Esc` back |
| Checklists | `Space` toggle, `A` all/none, `Enter` continue |
| Triage list | type to search titles, `Backspace`, `↑` `↓` `PgUp` `PgDn`, `Enter` set status, `Esc` clears the search first and then goes back |
| Status picker | `1` Completed, `2` Postponed, `3` Dismissed, `4` details |
| Details view | `P` Postponed, `C` Completed, `D` Dismiss, `↑` `↓` scroll resources, `Esc` back |

## CSV export (task planner)

The export has one row per recommendation, in UTF-8 with BOM so that Excel reads it correctly.

| Column | Content |
|--------|---------|
| `TaskName` | Recommendation title |
| `Bucket` | Review name |
| `Priority` | Critical / High / Medium / Low / Informational |
| `Status` | Active / Postponed / Completed / Dismissed |
| `Description` | Description, benefits, account team notes and link |
| `Labels` | `Resiliency;<Priority>;<Workload>` |
| `Workload` | Workload name of the review |
| `ActiveResources` … `DismissedResources` | Number of resources in each status |
| `ImpactedResourceCount` | Number of unique impacted resources |
| `ImpactedResources` | Resource IDs separated by `; ` (only if you choose to include them; they are then loaded first) |
| `Category`, `LearnMoreLink`, `RecommendationTypeId`, `ReviewId` | Reference data |

## How it works (APIs)

The tool calls ARM REST directly, using a token from `Get-AzAccessToken`. Only `Az.Accounts` is needed.

| Purpose | Call |
|---------|------|
| Reviews | `GET /subscriptions/{sub}/providers/Microsoft.Advisor/resiliencyReviews` (tries `2026-03-01-preview` first, then falls back to older versions), plus Resource Graph (see [Review discovery](#review-discovery)) |
| Titles and texts | Resource Graph `advisorresources` (`label`, `description`, `potentialBenefits`, `notes`). The ARM list API omits these for review items. Also narrows which subscriptions are scanned. |
| Recommendation counts | Resource Graph `advisorresources`, `summarize` per review, recommendation and status (one row per unique resource) |
| Affected resources | Resource Graph `advisorresources`, filtered by review and recommendation, loaded on demand (see [Counts first](#counts-first-resources-on-demand)) |
| Set status | `PATCH …/Microsoft.Advisor/recommendations/{name}` with `recommendationStatus` (`Postponed`, `Completed`, `Dismissed`), plus `recommendationDismissReason` or `postponedUntilDateTime` |
| Verify | `GET {resourceId}/providers/Microsoft.Advisor/recommendations/{name}` after each change |

> **Linked recommendations:** review recommendations on the same resource often share one `recommendationTypeId`. Azure may apply a status change to all of them, including those in other reviews. The tool updates them one at a time, warns you before the change, and re-reads and reports the related items afterwards.

> Microsoft retired the old triage flow (Pending / Accepted / Rejected). The statuses are now **Active**, **Postponed**, **Completed** and **Dismissed**. See [Azure Advisor resiliency reviews](https://learn.microsoft.com/azure/advisor/advisor-resiliency-reviews).
>
> Older reviews can still hold a legacy copy (GUID name, only `trackedProperties.state`) next to the current object for the same resource. Like the portal, the tool counts each resource once and uses the current object; legacy-only items take their status from `trackedProperties.state`.

## Structure

```text
ResiliencyReviewBuddy/
├─ Start-ResiliencyTriage.ps1         # entry point / flow
├─ modules/
│  ├─ ResiliencyTriage.Azure.psm1     # auth, REST, grouping, export, background update, demo data
│  └─ ResiliencyTriage.Tui.psm1       # TUI toolkit (menus, checklists, live filter list, detail view)
├─ tests/Test-ResiliencyTriage.ps1    # offline tests
└─ assets/resiliency-triage-banner.svg
```

Run the tests with:

```powershell
pwsh -NoProfile -File .\tests\Test-ResiliencyTriage.ps1
```

## Related

- [chrochma/assesmentbuddy](https://github.com/chrochma/assesmentbuddy): Well-Architected assessment tool that uses the same Advisor review APIs
