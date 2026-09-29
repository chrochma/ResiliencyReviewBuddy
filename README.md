<p align="center">
  <img src="assets/resiliency-triage-banner.svg" alt="Resiliency Review Triage" width="100%">
</p>

# Resiliency Review Triage

A PowerShell TUI (text user interface) for the **resiliency reviews** your Microsoft account team shares with you in [Azure Advisor](https://learn.microsoft.com/azure/advisor/advisor-resiliency-reviews). With it you can:

- track the progress of one, several or all reviews at once,
- export the recommendations as a CSV to import into a task planner,
- triage recommendations quickly by setting **Postponed**, **Completed** or **Dismissed** on *every* impacted resource in one step, with the update running in the background.

## Features

| Step | What happens |
|------|--------------|
| **Sign-in** | Finds an existing `Az` context, shows the account and tenant, and asks if you want to reuse it. Otherwise it runs `Connect-AzAccount` (browser or `-UseDeviceAuthentication`). |
| **Review selection** | Lists every resiliency review in your subscriptions. Pick reviews with checkboxes (`Space` toggles one, `A` toggles all). |
| **Progress overview** | Stacked progress bar with counts for the selected reviews and for each review. Counts are shown per recommendation and per resource: **Active** (Not started + In progress), **Postponed**, **Completed** and **Dismissed** (formerly *Rejected*). |
| **Export** | Writes a task-planner CSV of all recommendations, or only the priorities you select. You can export only *Active* work or all statuses. |
| **Triage** | Lists **all recommendations** of the selected reviews, sorted Critical → High → Medium → Low. Typing searches the **recommendation titles** live. Each row shows the title, number of affected resources, a short description and the current status. |
| **Change status** | `Enter` on a recommendation opens the status picker. It shows the current status and switches **all affected resources** to **Completed**, **Postponed** or **Dismissed**. Dismiss asks for a reason; Postpone asks for a date. A details view (description, benefits, notes, resources) is one option away. |
| **Background update** | The update runs as a background thread job, so you can keep triaging. Every resource is **re-read after the update** and the live status decides the result, so an API error on a change that Azure applied anyway still counts as a success. The TUI reports how many resources were **verified** and how many **failed**. Deleted resources are skipped. Details go to `exports\logs\update-*.csv`. |

## Prerequisites

- PowerShell **7.2+** in a real terminal (Windows Terminal recommended)
- `Az.Accounts` module: `Install-Module Az.Accounts -Scope CurrentUser`
- `ThreadJob` module (ships with PowerShell 7)
- RBAC: **Reader** to view reviews. To change statuses you need write access to `Microsoft.Advisor/recommendations` (e.g. **Advisor Recommendations Contributor**, **Contributor**).

## Usage

```powershell
cd .\AIApps\ResiliencyTriage

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
| `-SubscriptionId` | Only scan these subscriptions (default: all enabled) |
| `-UseDeviceAuthentication` | Device code sign-in |
| `-ExportPath` | Folder for CSV exports and failure logs (default `.\exports`) |
| `-Demo` | Offline demo mode |

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
| `ImpactedResources` | Resource IDs separated by `; ` |
| `Category`, `LearnMoreLink`, `RecommendationTypeId`, `ReviewId` | Reference data |

## How it works (APIs)

The tool calls ARM REST directly, using a token from `Get-AzAccessToken`. Only `Az.Accounts` is needed.

| Purpose | Call |
|---------|------|
| Reviews | `GET /subscriptions/{sub}/providers/Microsoft.Advisor/resiliencyReviews` (tries `2026-03-01-preview` first, then falls back to older versions) |
| Titles and texts | Resource Graph `advisorresources` (`label`, `description`, `potentialBenefits`, `notes`). The ARM list API omits these for review items. Also narrows which subscriptions are scanned. |
| Recommendations | `GET /subscriptions/{sub}/providers/Microsoft.Advisor/recommendations`, keeping only items that link to a review (`properties.review`) |
| Set status | `PATCH …/Microsoft.Advisor/recommendations/{name}` with `recommendationStatus` (`Postponed`, `Completed`, `Dismissed`), plus `recommendationDismissReason` or `postponedUntilDateTime` |
| Verify | `GET {resourceId}/providers/Microsoft.Advisor/recommendations/{name}` after each change |

> **Linked recommendations:** review recommendations on the same resource often share one `recommendationTypeId`. Azure may apply a status change to all of them, including those in other reviews. The tool updates them one at a time, warns you before the change, and re-reads and reports the related items afterwards.

> Microsoft retired the old triage flow (Pending / Accepted / Rejected). The statuses are now **Active**, **Postponed**, **Completed** and **Dismissed**. See [Azure Advisor resiliency reviews](https://learn.microsoft.com/azure/advisor/advisor-resiliency-reviews).

## Structure

```text
ResiliencyTriage/
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
