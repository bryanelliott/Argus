#requires -Version 5.1
<#
.SYNOPSIS
Finds small x64 B-series VMs in the subscription's allowed deployment regions.
.PARAMETER Subscription
Optional subscription name or ID. Otherwise reuses Azure CLI's current subscription.
.PARAMETER PassThru
Returns objects for export or further processing instead of a formatted table.
#>
[CmdletBinding()]
param(
    [string] $Subscription,
    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'
# Handle native exit codes ourselves, including in PowerShell 7.
$PSNativeCommandUseErrorActionPreference = $false

$azCommand = Get-Command az -ErrorAction SilentlyContinue
if (-not $azCommand) {
    throw 'Azure CLI is required. Install it from https://learn.microsoft.com/cli/azure/install-azure-cli and reopen PowerShell.'
}

function Invoke-AzJson {
    param([string[]] $Arguments)

    # Windows az.cmd expands arguments inside an IF block. Preserve quotes around
    # atScope() so cmd.exe does not interpret its parentheses as batch syntax.
    $nativeArguments = @($Arguments | ForEach-Object {
        if ($azCommand.Source -match '\.(cmd|bat)$' -and $_ -eq 'atScope()') {
            '"atScope()"'
        }
        else { $_ }
    })
    $errorFile = [System.IO.Path]::GetTempFileName()
    try {
        $raw = & $azCommand @nativeArguments --output json --only-show-errors 2> $errorFile
        if ($LASTEXITCODE -ne 0) {
            $detail = Get-Content -LiteralPath $errorFile -Raw
            throw "Azure CLI failed (az $($Arguments -join ' ')): $detail"
        }
        if ($raw) {
            $parsed = ($raw -join "`n") | ConvertFrom-Json
            # Explicitly enumerate JSON arrays consistently in Windows PowerShell and PS 7.
            return $parsed
        }
    }
    finally {
        Remove-Item -LiteralPath $errorFile -Force
    }
}

# account show reads the cached selection; a token request checks that login still works.
$previousAccount = $null
try { $previousAccount = Invoke-AzJson -Arguments @('account', 'show') }
catch { Write-Verbose 'No cached Azure CLI account is available.' }

$targetSubscription = $Subscription
if (-not $targetSubscription -and $previousAccount) {
    $targetSubscription = $previousAccount.id
}

$needsLogin = -not $previousAccount
if (-not $needsLogin) {
    try {
        $null = Invoke-AzJson -Arguments @('account', 'get-access-token')
    }
    catch { $needsLogin = $true }
}

if ($needsLogin) {
    Write-Host 'Signing in to Azure...'
    # Let Azure CLI display its interactive login/subscription selection prompts.
    & az login --output none --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'Azure login failed. Run az login and try again.' }
}

if ($targetSubscription) {
    try {
        $null = Invoke-AzJson -Arguments @('account', 'set', '--subscription', $targetSubscription)
    }
    catch {
        if ($Subscription -or -not $needsLogin) { throw }
        Write-Warning 'The previous subscription is unavailable. Using the subscription selected during login.'
    }
}

$account = Invoke-AzJson -Arguments @('account', 'show')
if (-not $account.id) { throw 'No subscription is selected. Run az login and select your student subscription.' }
Write-Host "Subscription: $($account.name) ($($account.id))"

# Include inherited assignments, but exclude assignments on child resource groups.
$assignments = @(Invoke-AzJson -Arguments @(
    'policy', 'assignment', 'list', '--subscription', $account.id,
    '--disable-scope-strict-match', 'true', '--filter', 'atScope()'
))
$matchingPolicies = @(
    foreach ($assignment in $assignments) {
        # Azure CLI versions may return flattened or ARM-style properties.
        $policy = $assignment
        if ($assignment.properties) { $policy = $assignment.properties }
        if ($policy.displayName -eq 'Allowed resource deployment regions' -and
            $policy.enforcementMode -ne 'DoNotEnforce') {
            $policy
        }
    }
)
if ($matchingPolicies.Count -eq 0) {
    throw "No enforced 'Allowed resource deployment regions' assignment was found. Verify the selected subscription above."
}

# Save the policy parameter in this variable. Multiple policies must all allow a region.
$listOfAllowedLocations = $null
foreach ($policy in $matchingPolicies) {
    $parameter = $policy.parameters.listOfAllowedLocations
    if ($null -eq $parameter -or $null -eq $parameter.value) {
        throw "The region policy is missing its listOfAllowedLocations parameter."
    }
    $locations = @($parameter.value | ForEach-Object {
        if (-not [string]::IsNullOrWhiteSpace($_)) { $_.Trim().ToLowerInvariant() }
    } | Sort-Object -Unique)
    if ($null -eq $listOfAllowedLocations) {
        $listOfAllowedLocations = $locations
    }
    else {
        $listOfAllowedLocations = @($listOfAllowedLocations | Where-Object { $_ -in $locations })
    }
}
if ($listOfAllowedLocations.Count -eq 0) { throw 'The region policies have no allowed locations in common.' }

$results = foreach ($location in $listOfAllowedLocations) {
    Write-Host "Checking $location..."
    try {
        $skus = @(Invoke-AzJson -Arguments @(
            'vm', 'list-skus', '--subscription', $account.id,
            '--location', $location, '--resource-type', 'virtualMachines', '--all', 'true'
        ))
        $candidates = @(
            foreach ($sku in $skus) {
                if ($sku.resourceType -ne 'virtualMachines' -or $sku.name -notmatch '^Standard_B' -or
                    $location -notin $sku.locations) { continue }

                # A zone-only restriction does not prevent a VM deployed without a zone.
                # Fail closed for location/unknown restrictions returned for this region.
                $blockingRestrictions = @($sku.restrictions | Where-Object { $_ -and $_.type -ne 'Zone' })
                if ($blockingRestrictions.Count -gt 0) { continue }

                $capabilities = @{}
                foreach ($capability in $sku.capabilities) {
                    $capabilities[$capability.name] = $capability.value
                }
                if ($capabilities['CpuArchitectureType'] -ne 'x64') { continue }
                $cpu = 0
                $memory = 0.0
                if (-not [int]::TryParse([string]$capabilities['vCPUs'], [ref]$cpu)) { continue }
                if (-not [double]::TryParse([string]$capabilities['MemoryGB'],
                    [System.Globalization.NumberStyles]::Float,
                    [System.Globalization.CultureInfo]::InvariantCulture, [ref]$memory)) { continue }
                if ($cpu -notin @(1, 2) -or $memory -lt 2 -or $memory -gt 4) { continue }

                [pscustomobject]@{
                    Location = $location
                    RecommendedSKU = $sku.name
                    vCPUs = $cpu
                    MemoryGB = $memory
                    Status = 'Match (no zone specified)'
                }
            }
        )
        # Prefer the smallest eligible hardware footprint; this is not a price comparison.
        $recommendation = $candidates | Sort-Object vCPUs, MemoryGB, RecommendedSKU | Select-Object -First 1
        if ($recommendation) { $recommendation }
        else {
            [pscustomobject]@{
                Location = $location; RecommendedSKU = $null; vCPUs = $null
                MemoryGB = $null; Status = 'No matching available SKU'
            }
        }
    }
    catch {
        Write-Warning "Could not query ${location}: $_"
        [pscustomobject]@{
            Location = $location; RecommendedSKU = $null; vCPUs = $null
            MemoryGB = $null; Status = 'Query failed; see warning'
        }
    }
}

if ($PassThru) { $results }
else { $results | Format-Table Location, RecommendedSKU, vCPUs, MemoryGB, Status -AutoSize }
