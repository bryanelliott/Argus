# Offline integration checks. No Azure account or test framework required.
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Get-StudentVmRecommendation.ps1'
$global:ArgusTest_loginCount = 0
$global:ArgusTest_expired = $false
$global:ArgusTest_nested = $false
$global:ArgusTest_missingPolicy = $false
$global:ArgusTest_selectedSubscription = $null
$global:ArgusTest_queriedRegions = @()

function New-TestSku {
    param($Name, $Cpu, $Memory, $Architecture = 'x64', $Restrictions = @())
    @{
        name = $Name; resourceType = 'virtualMachines'; locations = @('eastus')
        restrictions = $Restrictions
        capabilities = @(
            @{ name = 'vCPUs'; value = "$Cpu" }
            @{ name = 'MemoryGB'; value = "$Memory" }
            @{ name = 'CpuArchitectureType'; value = $Architecture }
        )
    }
}

function az {
    $global:LASTEXITCODE = 0
    $command = $args[0..1] -join ' '
    switch ($command) {
        'account show' { '{"id":"student-id","name":"Azure for Students"}' }
        'account get-access-token' {
            if ($global:ArgusTest_expired) { $global:LASTEXITCODE = 1 }
            else { '{"accessToken":"test-only"}' }
        }
        'login --output' { $global:ArgusTest_loginCount++; $global:ArgusTest_expired = $false }
        'account set' { $global:ArgusTest_selectedSubscription = $args[3] }
        'policy assignment' {
            if ($global:ArgusTest_missingPolicy) { '[]'; break }
            $policies = @(
                @{
                    displayName = 'Allowed resource deployment regions'
                    parameters = @{ listOfAllowedLocations = @{ value = @('eastus', 'westus', 'centralus', 'northus') } }
                }
                @{
                    displayName = 'Allowed resource deployment regions'
                    parameters = @{ listOfAllowedLocations = @{ value = @('eastus', 'westus', 'centralus') } }
                }
                @{
                    displayName = 'Allowed resource deployment regions'; enforcementMode = 'DoNotEnforce'
                    parameters = @{ listOfAllowedLocations = @{ value = @('ignored') } }
                }
            )
            if ($global:ArgusTest_nested) { $policies = @($policies | ForEach-Object { @{ properties = $_ } }) }
            ConvertTo-Json -InputObject $policies -Depth 10
        }
        'vm list-skus' {
            $region = $args[[array]::IndexOf($args, '--location') + 1]
            $global:ArgusTest_queriedRegions += $region
            if ($region -eq 'centralus') { $global:LASTEXITCODE = 1; break }
            if ($region -eq 'westus') { '[]'; break }
            $skus = @(
                (New-TestSku 'Standard_B2s' 2 4)
                (New-TestSku 'Standard_B1ms' 1 2 'x64' @(@{ type = 'Zone' }))
                (New-TestSku 'Standard_B0restricted' 1 2 'x64' @(@{ type = 'Location' }))
                (New-TestSku 'Standard_B0arm' 1 2 'Arm64')
                (New-TestSku 'Standard_B0unknown' 1 2 '')
                (New-TestSku 'Standard_B1s' 1 1)
                (New-TestSku 'Standard_B4ms' 4 16)
                (New-TestSku 'Standard_D1' 1 2)
            )
            ConvertTo-Json -InputObject $skus -Depth 10
        }
        default { throw "Unexpected mock command: $args" }
    }
}

function Assert-True($Condition, $Message) {
    if (-not $Condition) { throw "FAILED: $Message" }
}

$results = @(& $scriptPath -PassThru -WarningAction SilentlyContinue)
Assert-True ($global:ArgusTest_loginCount -eq 0) 'Valid login should be reused.'
Assert-True ($results.Count -eq 3) 'Policy intersection must include three regions.'
Assert-True ('northus' -notin $global:ArgusTest_queriedRegions) 'Excluded regions must not be queried.'
Assert-True (($results | Where-Object Location -eq 'eastus').RecommendedSKU -eq 'Standard_B1ms') 'Choose the smallest eligible x64 SKU, allowing zone-only restrictions.'
Assert-True (($results | Where-Object Location -eq 'westus').Status -eq 'No matching available SKU') 'Report no match.'
Assert-True (($results | Where-Object Location -eq 'centralus').Status -eq 'Query failed; see warning') 'Report individual query errors and continue.'

$global:ArgusTest_expired = $true
$global:ArgusTest_nested = $true
$results = @(& $scriptPath -PassThru -WarningAction SilentlyContinue)
Assert-True ($global:ArgusTest_loginCount -eq 1) 'Expired authentication must trigger login.'
Assert-True ($global:ArgusTest_selectedSubscription -eq 'student-id') 'Restore the previous subscription.'
Assert-True (($results | Where-Object Location -eq 'eastus').RecommendedSKU -eq 'Standard_B1ms') 'Support nested policy properties.'

$null = & $scriptPath -Subscription 'explicit-id' -PassThru -WarningAction SilentlyContinue
Assert-True ($global:ArgusTest_selectedSubscription -eq 'explicit-id') 'Honor an explicit subscription.'

$global:ArgusTest_missingPolicy = $true
$failed = $false
try { $null = & $scriptPath -PassThru }
catch { $failed = $_.Exception.Message -like "No enforced*" }
Assert-True $failed 'Stop if the required policy is missing.'
Write-Host 'All offline checks passed.'
