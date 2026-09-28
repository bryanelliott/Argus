# Exercises real PowerShell 5.1 runspaces with an offline CLI fixture.
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Get-StudentVmRecommendation.ps1'
$parseErrors = $null
$tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors) { throw $parseErrors }
foreach ($name in @('Invoke-AzJson', 'Invoke-RegionQueries')) {
    $node = $ast.Find({ param($item)
        $item -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $name
    }, $true)
    . ([scriptblock]::Create($node.Extent.Text))
}
$fixturePath = Join-Path ([IO.Path]::GetTempPath()) ("argus-cli-{0}.ps1" -f [guid]::NewGuid())
try {
    @'
$global:LASTEXITCODE = 0
$location = $args[[array]::IndexOf($args, '--location') + 1]
$subscription = $args[[array]::IndexOf($args, '--subscription') + 1]
if ($subscription -ne 'test-subscription') { throw 'Subscription was not forwarded.' }
if ($args[1] -eq 'list-skus') {
    $start = [datetime]::UtcNow.Ticks
    Start-Sleep -Milliseconds 800
    @{ location = $location; start = $start; end = [datetime]::UtcNow.Ticks } | ConvertTo-Json
}
elseif ($location -eq 'quota-failure') { $global:LASTEXITCODE = 1 }
else { '[{"name":{"value":"standardBSFamily"},"currentValue":0,"limit":4}]' }
'@ | Set-Content -LiteralPath $fixturePath
    $azCommand = Get-Command $fixturePath
    $results = @(Invoke-RegionQueries -Locations @('eastus', 'westus', 'quota-failure', 'centralus') -SubscriptionId 'test-subscription' -Concurrency 2)
    if ($results.Count -ne 4) { throw 'Expected one result per region.' }
    $events = @($results | ForEach-Object {
        if ($_.Skus[0].location -ne $_.Location) { throw 'Results were assigned to the wrong region.' }
        [pscustomobject]@{ Time = $_.Skus[0].start; Delta = 1 }
        [pscustomobject]@{ Time = $_.Skus[0].end; Delta = -1 }
    })
    $active = 0
    $maximum = 0
    foreach ($event in ($events | Sort-Object Time, Delta)) {
        $active += $event.Delta
        $maximum = [math]::Max($maximum, $active)
    }
    if ($maximum -ne 2) { throw "Expected two overlapping queries with throttle two; got $maximum." }
    $failed = $results | Where-Object Location -eq 'quota-failure'
    if (-not $failed.QuotaError -or $failed.SkuError) { throw 'Quota failure was not isolated.' }
    if (($results | Where-Object Location -eq 'eastus').Usage[0].limit -ne 4) { throw 'Quota output was lost.' }
    Write-Host 'Parallel query checks passed (two concurrent queries; throttle respected).'
}
finally {
    Remove-Item -LiteralPath $fixturePath -Force -ErrorAction SilentlyContinue
}
