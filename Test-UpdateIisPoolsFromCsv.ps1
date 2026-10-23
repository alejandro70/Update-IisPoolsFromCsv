$ErrorActionPreference = 'Stop'
$productionScript = Join-Path $PSScriptRoot 'Update-IisPoolsFromCsv.ps1'
$tokens = $null
$parseErrors = $null
$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $productionScript,
    [ref]$tokens,
    [ref]$parseErrors
)

if ($parseErrors.Count -gt 0) {
    throw "Could not parse production script: $($parseErrors[0].Message)"
}

function Reset-TestState {
    $script:testState = @{
        IisAvailable = $true
        PoolExists = $true
        CsvExists = $true
        Pool = $null
        CsvRows = @()
        SetItemCalls = @()
        RestartedPools = @()
    }
}

function Get-PSDrive {
    param([string]$Name)

    if ($Name -eq 'IIS' -and $script:testState.IisAvailable) {
        return [pscustomobject]@{ Name = 'IIS' }
    }
}

function Test-Path {
    param([string]$Path)

    if ($Path -like 'IIS:\AppPools\*') {
        return $script:testState.PoolExists
    }

    return $script:testState.CsvExists
}

function Get-Item {
    param([string]$Path)

    return $script:testState.Pool
}

function Set-Item {
    process {
        $script:testState.SetItemCalls += ,$_
    }
}

function Restart-WebAppPool {
    param([string]$Name)

    $script:testState.RestartedPools += $Name
}

function Import-Csv {
    param([string]$Path)

    return $script:testState.CsvRows
}

function Assert-Equal {
    param(
        [object]$Actual,
        [object]$Expected,
        [string]$Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-Throws {
    param(
        [scriptblock]$Action,
        [string]$Message
    )

    $threw = $false
    try {
        & $Action
    }
    catch {
        $threw = $true
    }

    if (-not $threw) {
        throw $Message
    }
}

foreach ($functionAst in $scriptAst.FindAll(
    { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },
    $false
)) {
    . ([scriptblock]::Create($functionAst.Extent.Text))
}

$testsPassed = 0

Reset-TestState
$script:testState.Pool = [pscustomobject]@{
    processModel = [pscustomobject]@{
        identityType = 'ApplicationPoolIdentity'
        userName = ''
        password = 'old-password'
    }
    State = 'Started'
}

Set-IisAppPoolGmsa -PoolNames 'ExamplePool' -GmsaUser 'DOMAIN\svc-example$' -RestartPool
Assert-Equal $script:testState.Pool.processModel.identityType 'SpecificUser' 'Pool identity type was not updated.'
Assert-Equal $script:testState.Pool.processModel.userName 'DOMAIN\svc-example$' 'Pool account was not updated.'
Assert-Equal $script:testState.Pool.processModel.password '' 'Pool password should be blank for the gMSA.'
Assert-Equal $script:testState.SetItemCalls.Count 1 'Pool settings were not saved exactly once.'
Assert-Equal $script:testState.RestartedPools.Count 1 'Started pool was not restarted exactly once.'
$testsPassed++

Reset-TestState
$script:testState.Pool = [pscustomobject]@{
    processModel = [pscustomobject]@{
        identityType = 'ApplicationPoolIdentity'
        userName = ''
        password = ''
    }
    State = 'Stopped'
}

Set-IisAppPoolGmsa -PoolNames 'StoppedPool' -GmsaUser 'DOMAIN\svc-example$' -RestartPool
Assert-Equal $script:testState.RestartedPools.Count 0 'Stopped pool should not be restarted.'
$testsPassed++

Reset-TestState
$script:testState.PoolExists = $false
Set-IisAppPoolGmsa -PoolNames 'MissingPool' -GmsaUser 'DOMAIN\svc-example$'
Assert-Equal $script:testState.SetItemCalls.Count 0 'A missing pool should not be changed.'
$testsPassed++

Reset-TestState
$script:testState.CsvRows = @(
    [pscustomobject]@{
        Servidor = 'SVR01'
        IP = '192.0.2.2'
        Clasificacion = 'IIS Pool'
        Componente = 'WrongIpPool'
        gMSA = 'DOMAIN\svc-example$'
    }
    [pscustomobject]@{
        Servidor = 'SVR01'
        IP = '172.25.109.151'
        Clasificacion = 'Website'
        Componente = 'WrongTypePool'
        gMSA = 'DOMAIN\svc-example$'
    }
    [pscustomobject]@{
        Servidor = 'SVR01'
        IP = '172.25.109.151'
        Clasificacion = 'IIS Pool'
        Componente = 'MissingGmsaPool'
        gMSA = ' '
    }
)

Update-IisPoolsFromCsv -CsvPath 'pools.csv' -CurrentServerIp '172.25.109.151' -CurrentServerName 'SVR01'
Assert-Equal $script:testState.SetItemCalls.Count 0 'Rows failing the CSV filters should not change a pool.'
$testsPassed++

Reset-TestState
$script:testState.CsvRows = @(
    [pscustomobject]@{
        Servidor = 'OTHER-SERVER'
        IP = '172.25.109.151'
        Clasificacion = 'IIS Pool'
        Componente = 'WrongServerPool'
        gMSA = 'DOMAIN\svc-example$'
    }
)

Update-IisPoolsFromCsv -CsvPath 'pools.csv' -CurrentServerIp '172.25.109.151' -CurrentServerName 'SVR01'
Assert-Equal $script:testState.SetItemCalls.Count 0 'A row for another server should not change a pool.'
$testsPassed++

Reset-TestState
$script:testState.Pool = [pscustomobject]@{
    processModel = [pscustomobject]@{
        identityType = 'ApplicationPoolIdentity'
        userName = ''
        password = 'old-password'
    }
    State = 'Started'
}
$script:testState.CsvRows = @(
    [pscustomobject]@{
        Servidor = 'SVR01'
        IP = '172.25.109.151'
        Clasificacion = 'IIS Pool'
        Componente = 'ExamplePool'
        gMSA = 'DOMAIN\svc-example$'
    }
)

Update-IisPoolsFromCsv -CsvPath 'pools.csv' -CurrentServerIp '172.25.109.151' -CurrentServerName 'SVR01' -RestartPool
Assert-Equal $script:testState.Pool.processModel.identityType 'SpecificUser' 'CSV row did not change the pool identity type.'
Assert-Equal $script:testState.Pool.processModel.userName 'DOMAIN\svc-example$' 'CSV row did not set the pool gMSA.'
Assert-Equal $script:testState.Pool.processModel.password '' 'CSV row did not clear the pool password.'
Assert-Equal $script:testState.SetItemCalls.Count 1 'CSV row did not save the pool changes exactly once.'
Assert-Equal $script:testState.RestartedPools.Count 1 'CSV row did not restart the started pool exactly once.'
$testsPassed++

Reset-TestState
$script:testState.CsvExists = $false
Assert-Throws {
    Update-IisPoolsFromCsv -CsvPath 'missing.csv' -CurrentServerIp '172.25.109.151' -CurrentServerName 'SVR01'
} 'Missing CSV should cause an error.'
$testsPassed++

Reset-TestState
$script:testState.IisAvailable = $false
Assert-Throws {
    Set-IisAppPoolGmsa -PoolNames 'ExamplePool' -GmsaUser 'DOMAIN\svc-example$'
} 'Unavailable IIS provider should cause an error.'
$testsPassed++

Write-Host "Passed $testsPassed PowerShell tests."
