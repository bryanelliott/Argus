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

The table includes each location, recommended SKU, CPU count, RAM, and status. Regions with no match or a failed query remain visible. To save results:

```powershell
.\Get-StudentVmRecommendation.ps1 -PassThru |
    Export-Csv .\vm-recommendations.csv -NoTypeInformation
```

Recommendations assume deployment **without an availability zone**. Zone-only restrictions do not exclude a size. Available capacity, remaining vCPU quota, image compatibility, and other policies can still prevent deployment; this script does not deploy resources or validate all such constraints.

Azure CLI references: [policy assignment list](https://learn.microsoft.com/cli/azure/policy/assignment#az-policy-assignment-list) and [vm list-skus](https://learn.microsoft.com/cli/azure/vm#az-vm-list-skus).

