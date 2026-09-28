# Argus for Azure

Find deployment regions and small VM sizes for COMP77 students at St. Lawrence College using Azure for Students subscriptions.

Requires PowerShell 5.1 or later and [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli).

```powershell
.\Get-StudentVmRecommendation.ps1
```

The script reuses Azure CLI's selected subscription and checks authentication. If sign-in is needed, it runs `az login` and attempts to restore the previously selected subscription. On first use, select your student subscription during login. You can also choose one explicitly:

```powershell
.\Get-StudentVmRecommendation.ps1 -Subscription 'Azure for Students'
```

It reads the **Allowed resource deployment regions** policy assignment and saves its `listOfAllowedLocations` parameter in a script variable. Inherited subscription policies are included; assignments that are not enforced are skipped. If multiple matching policies apply, only their shared regions are checked. A missing policy produces an error instead of assuming all regions are allowed.

For each region, the script recommends a **B-series, x64 VM with 1 or 2 vCPUs and 2 to 4 GB RAM**, excluding sizes with regional subscription restrictions. It prefers fewer vCPUs, then less RAM, then SKU name for a stable tie-break. This favors a small hardware footprint; it does not compare prices. Missing architecture information is not assumed to mean x64.

Regional checks run concurrently, with up to five regions active at once. Each worker runs `az vm list-skus` and `az vm list-usage` for its region. To adjust concurrency (use `1` for serial execution):

```powershell
.\Get-StudentVmRecommendation.ps1 -ThrottleLimit 6
```

The table includes each location, recommended SKU, CPU count, RAM, quota family, quota usage/limit, remaining vCPUs, and status. Quota is matched using the SKU's actual family identifier, so older B-series and newer B-series families use their own limits. For example, `2/4 (2 free)` means two vCPUs are used out of a four-vCPU family limit. Insufficient quota is flagged without hiding the matching SKU or changing the hardware ranking. Unknown quota is not treated as zero. Where no SKU matches, all returned B-family quotas are shown for that region.

Regions with no match or a failed query remain visible. `-PassThru` also exposes numeric `QuotaUsed`, `QuotaLimit`, and `QuotaRemaining` fields plus `QuotaStatus`. To save results:

```powershell
.\Get-StudentVmRecommendation.ps1 -PassThru |
    Export-Csv .\vm-recommendations.csv -NoTypeInformation
```

Recommendations assume deployment **without an availability zone**. Zone-only restrictions do not exclude a size. Quota is a snapshot, measured in vCPUs rather than VM count. Total regional vCPU quota is a separate limit and is not checked. Available capacity, image compatibility, and other policies can also prevent deployment; this script does not deploy resources or validate all such constraints.

Azure CLI references: [policy assignment list](https://learn.microsoft.com/cli/azure/policy/assignment#az-policy-assignment-list), [vm list-skus](https://learn.microsoft.com/cli/azure/vm#az-vm-list-skus), and [vCPU quotas / list-usage](https://learn.microsoft.com/azure/virtual-machines/quotas).

