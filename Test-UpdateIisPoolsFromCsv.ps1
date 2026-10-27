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

# Restablece los datos simulados para aislar cada prueba.
function Reset-TestState {
    $script:testState = @{
        IisAvailable = $true
        PoolExists = $true
        CsvExists = $true
        CsvHeaders = @('Servidor', 'IP', 'Componente', 'Clasificacion', 'gMSA')
        Pool = $null
        CsvRows = @()
        FailSetItem = $false
        FailRestart = $false
        SetItemCalls = @()
        RestartedPools = @()
    }
}

# Estos dobles sustituyen las dependencias de IIS y del sistema de archivos.
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
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)]
        [object]$InputObject
    )

    process {
        if ($script:testState.FailSetItem) {
            throw 'Simulated save failure.'
        }

        $script:testState.SetItemCalls += ,$InputObject
    }
}

function Restart-WebAppPool {
    [CmdletBinding()]
    param([string]$Name)

    if ($script:testState.FailRestart) {
        throw 'Simulated restart failure.'
    }

    $script:testState.RestartedPools += $Name
}

function Import-Csv {
    param([string]$Path)

    return $script:testState.CsvRows
}

# Carga las funciones reales sin ejecutar el bloque principal del script.
foreach ($functionAst in $scriptAst.FindAll(
    { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },
    $false
)) {
    . ([scriptblock]::Create($functionAst.Extent.Text))
}

$script:getCsvHeadersFunction = (Get-Command Get-CsvHeaders).ScriptBlock
# Simula el encabezado para probar la validación sin depender de archivos CSV.
function Get-CsvHeaders {
    param([string]$CsvPath)

    return $script:testState.CsvHeaders
}

# Lanza un error si el valor obtenido no coincide con el esperado.
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

# Confirma que la acción proporcionada produzca una excepción.
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

$testsPassed = 0

# Get-CsvHeaders_QuotedHeaders_ParsesFieldsCorrectly
Reset-TestState
$tempCsvPath = [System.IO.Path]::GetTempFileName()
try {
    Set-Content -LiteralPath $tempCsvPath -Value '"Servidor","IP, actual",Componente' -NoNewline
    $headers = @(& $script:getCsvHeadersFunction -CsvPath $tempCsvPath)
    Assert-Equal $headers.Count 3 'CSV headers were not parsed correctly.'
    Assert-Equal $headers[1] 'IP, actual' 'Quoted CSV header was not parsed correctly.'

    Set-Content -LiteralPath $tempCsvPath -Value '' -NoNewline
    Assert-Throws {
        & $script:getCsvHeadersFunction -CsvPath $tempCsvPath
    } 'An empty CSV file should cause an error.'
}
finally {
    Remove-Item -LiteralPath $tempCsvPath -Force
}
$testsPassed++

# Set-IisAppPoolGmsa_StartedPoolWithRestart_UpdatesIdentityAndRestartsPool
Reset-TestState
$script:testState.Pool = [pscustomobject]@{
    processModel = [pscustomobject]@{
        identityType = 'ApplicationPoolIdentity'
        userName = ''
        password = 'old-password'
    }
    State = 'Started'
}

$null = Set-IisAppPoolGmsa -PoolNames 'ExamplePool' -GmsaUser 'DOMAIN\svc-example$' -RestartPool
Assert-Equal $script:testState.Pool.processModel.identityType 'SpecificUser' 'Pool identity type was not updated.'
Assert-Equal $script:testState.Pool.processModel.userName 'DOMAIN\svc-example$' 'Pool account was not updated.'
Assert-Equal $script:testState.Pool.processModel.password '' 'Pool password should be blank for the gMSA.'
Assert-Equal $script:testState.SetItemCalls.Count 1 'Pool settings were not saved exactly once.'
Assert-Equal $script:testState.RestartedPools.Count 1 'Started pool was not restarted exactly once.'
$testsPassed++

# Set-IisAppPoolGmsa_WhatIf_DoesNotSaveOrRestartPool
Reset-TestState
$script:testState.Pool = [pscustomobject]@{
    processModel = [pscustomobject]@{
        identityType = 'ApplicationPoolIdentity'
        userName = ''
        password = 'old-password'
    }
    State = 'Started'
}

$whatIfResult = Set-IisAppPoolGmsa -PoolNames 'ExamplePool' -GmsaUser 'DOMAIN\svc-example$' -RestartPool -WhatIf
Assert-Equal $whatIfResult.Status 'WhatIf' 'WhatIf should report a simulated change.'
Assert-Equal $script:testState.Pool.processModel.identityType 'ApplicationPoolIdentity' 'WhatIf should not change the pool identity.'
Assert-Equal $script:testState.SetItemCalls.Count 0 'WhatIf should not save pool settings.'
Assert-Equal $script:testState.RestartedPools.Count 0 'WhatIf should not restart the pool.'
$testsPassed++

# Set-IisAppPoolGmsa_StoppedPoolWithRestart_UpdatesIdentityWithoutRestarting
Reset-TestState
$script:testState.Pool = [pscustomobject]@{
    processModel = [pscustomobject]@{
        identityType = 'ApplicationPoolIdentity'
        userName = ''
        password = ''
    }
    State = 'Stopped'
}

$null = Set-IisAppPoolGmsa -PoolNames 'StoppedPool' -GmsaUser 'DOMAIN\svc-example$' -RestartPool
Assert-Equal $script:testState.RestartedPools.Count 0 'Stopped pool should not be restarted.'
$testsPassed++

# Set-IisAppPoolGmsa_MissingPool_SkipsPoolWithoutSaving
Reset-TestState
$script:testState.PoolExists = $false
$null = Set-IisAppPoolGmsa -PoolNames 'MissingPool' -GmsaUser 'DOMAIN\svc-example$'
Assert-Equal $script:testState.SetItemCalls.Count 0 'A missing pool should not be changed.'
$testsPassed++

# Update-IisPoolsFromCsv_RowsFailingFilters_SkipsRowsWithoutUpdatingPools
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

$filteredResult = Update-IisPoolsFromCsv -CsvPath 'pools.csv' -CurrentServerIp '172.25.109.151' -CurrentServerName 'SVR01'
Assert-Equal $script:testState.SetItemCalls.Count 0 'Rows failing the CSV filters should not change a pool.'
Assert-Equal $filteredResult.TotalRows 3 'The summary should include every CSV row.'
Assert-Equal $filteredResult.Skipped 3 'Rows failing the CSV filters should be counted as skipped.'
$testsPassed++

# Update-IisPoolsFromCsv_MissingRequiredColumns_ThrowsValidationError
Reset-TestState
$script:testState.CsvHeaders = @('Servidor', 'IP')
Assert-Throws {
    $null = Update-IisPoolsFromCsv -CsvPath 'pools.csv' -CurrentServerIp '172.25.109.151' -CurrentServerName 'SVR01'
} 'A CSV missing required columns should cause an error.'
$testsPassed++

# Update-IisPoolsFromCsv_DuplicateRequiredColumns_ThrowsValidationError
Reset-TestState
$script:testState.CsvHeaders = @('Servidor', 'IP', 'Componente', 'Clasificacion', 'gMSA', 'IP')
Assert-Throws {
    Update-IisPoolsFromCsv -CsvPath 'pools.csv' -CurrentServerIp '172.25.109.151' -CurrentServerName 'SVR01'
} 'A CSV with duplicated required columns should cause an error.'
$testsPassed++

# Update-IisPoolsFromCsv_HeaderOnlyCsv_ReturnsEmptySummary
Reset-TestState
$emptyResult = Update-IisPoolsFromCsv -CsvPath 'pools.csv' -CurrentServerIp '172.25.109.151' -CurrentServerName 'SVR01'
Assert-Equal $emptyResult.TotalRows 0 'A header-only CSV should report zero rows.'
Assert-Equal $emptyResult.Updated 0 'A header-only CSV should not update pools.'
$testsPassed++

# Update-IisPoolsFromCsv_MissingComponentOrGmsa_CountsRowsAsSkipped
Reset-TestState
$script:testState.CsvRows = @(
    [pscustomobject]@{
        Servidor = 'SVR01'
        IP = '172.25.109.151'
        Clasificacion = 'IIS Pool'
        Componente = ''
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
$incompleteResult = Update-IisPoolsFromCsv -CsvPath 'pools.csv' -CurrentServerIp '172.25.109.151' -CurrentServerName 'SVR01'
Assert-Equal $incompleteResult.Skipped 2 'Rows with missing component or gMSA should be reported as skipped.'
Assert-Equal $incompleteResult.Updated 0 'Incomplete rows should not update pools.'
$testsPassed++

# Update-IisPoolsFromCsv_ServerNameMismatch_SkipsRowWithoutUpdatingPool
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

$null = Update-IisPoolsFromCsv -CsvPath 'pools.csv' -CurrentServerIp '172.25.109.151' -CurrentServerName 'SVR01'
Assert-Equal $script:testState.SetItemCalls.Count 0 'A row for another server should not change a pool.'
$testsPassed++

# Update-IisPoolsFromCsv_WhatIf_ReportsSimulationWithoutSaving
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

$simulatedUpdate = Update-IisPoolsFromCsv -CsvPath 'pools.csv' -CurrentServerIp '172.25.109.151' -CurrentServerName 'SVR01' -RestartPool -WhatIf
Assert-Equal $simulatedUpdate.WhatIf 1 'The summary should count the simulated pool change.'
Assert-Equal $simulatedUpdate.Updated 0 'A simulated change should not count as an update.'
Assert-Equal $simulatedUpdate.Changes[0].Status 'WhatIf' 'The change details should identify the simulated action.'
Assert-Equal $script:testState.Pool.processModel.identityType 'ApplicationPoolIdentity' 'The update command should not change the pool during WhatIf.'
Assert-Equal $script:testState.SetItemCalls.Count 0 'The update command should not save pool settings during WhatIf.'
Assert-Equal $script:testState.RestartedPools.Count 0 'The update command should not restart pools during WhatIf.'
$testsPassed++

# Update-IisPoolsFromCsv_SaveFailure_CountsFailureAndIncludesErrorDetails
Reset-TestState
$script:testState.Pool = [pscustomobject]@{
    processModel = [pscustomobject]@{
        identityType = 'ApplicationPoolIdentity'
        userName = ''
        password = ''
    }
    State = 'Started'
}
$script:testState.FailSetItem = $true
$script:testState.CsvRows = @(
    [pscustomobject]@{
        Servidor = 'SVR01'
        IP = '172.25.109.151'
        Clasificacion = 'IIS Pool'
        Componente = 'SaveFailurePool'
        gMSA = 'DOMAIN\svc-example$'
    }
)
$saveFailureResult = Update-IisPoolsFromCsv -CsvPath 'pools.csv' -CurrentServerIp '172.25.109.151' -CurrentServerName 'SVR01' 2>$null
Assert-Equal $saveFailureResult.Failed 1 'A save failure should be counted.'
Assert-Equal $saveFailureResult.Errors.Count 1 'A save failure should include error details.'
if ($saveFailureResult.Errors[0] -notlike '*Simulated save failure*') {
    throw 'The save failure summary did not include its cause.'
}
$testsPassed++

# Update-IisPoolsFromCsv_RestartFailure_CountsFailureAndPreservesSavedSettings
Reset-TestState
$script:testState.Pool = [pscustomobject]@{
    processModel = [pscustomobject]@{
        identityType = 'ApplicationPoolIdentity'
        userName = ''
        password = ''
    }
    State = 'Started'
}
$script:testState.FailRestart = $true
$script:testState.CsvRows = @(
    [pscustomobject]@{
        Servidor = 'SVR01'
        IP = '172.25.109.151'
        Clasificacion = 'IIS Pool'
        Componente = 'RestartFailurePool'
        gMSA = 'DOMAIN\svc-example$'
    }
)
$restartFailureResult = Update-IisPoolsFromCsv -CsvPath 'pools.csv' -CurrentServerIp '172.25.109.151' -CurrentServerName 'SVR01' -RestartPool 2>$null
Assert-Equal $restartFailureResult.Failed 1 'A restart failure should be counted.'
Assert-Equal $restartFailureResult.Errors.Count 1 'A restart failure should include error details.'
Assert-Equal $script:testState.SetItemCalls.Count 1 'Pool settings should be saved before reporting a restart failure.'
if ($restartFailureResult.Errors[0] -notlike '*falló el reinicio*') {
    throw 'The restart failure summary should distinguish a restart failure.'
}
$testsPassed++

# Update-IisPoolsFromCsv_MatchingPoolRow_UpdatesPoolAndReportsSuccess
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

$successResult = Update-IisPoolsFromCsv -CsvPath 'pools.csv' -CurrentServerIp '172.25.109.151' -CurrentServerName 'SVR01' -RestartPool
Assert-Equal $script:testState.Pool.processModel.identityType 'SpecificUser' 'CSV row did not change the pool identity type.'
Assert-Equal $script:testState.Pool.processModel.userName 'DOMAIN\svc-example$' 'CSV row did not set the pool gMSA.'
Assert-Equal $script:testState.Pool.processModel.password '' 'CSV row did not clear the pool password.'
Assert-Equal $script:testState.SetItemCalls.Count 1 'CSV row did not save the pool changes exactly once.'
Assert-Equal $script:testState.RestartedPools.Count 1 'CSV row did not restart the started pool exactly once.'
Assert-Equal $successResult.Updated 1 'The summary should count a successfully updated pool.'
$testsPassed++

# Write-IisChangeLog_AppendsCsvEntries
$tempLogPath = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString() + '.csv')
try {
    $logEntry = [pscustomobject]@{
        Timestamp = '2026-01-01T00:00:00.0000000+00:00'
        Server = 'SVR01'
        PoolName = 'ExamplePool'
        GmsaUser = 'DOMAIN\svc-example$'
        Status = 'WhatIf'
        Message = 'Simulación de prueba'
    }
    Write-IisChangeLog -Path $tempLogPath -Entry $logEntry
    Write-IisChangeLog -Path $tempLogPath -Entry $logEntry

    $logLines = [System.IO.File]::ReadAllLines($tempLogPath)
    Assert-Equal $logLines.Count 3 'The change log should contain one header and both entries.'
    if ($logLines[0] -notlike '*Timestamp*PoolName*Status*') {
        throw 'The change log should have CSV column headers.'
    }
}
finally {
    if ([System.IO.File]::Exists($tempLogPath)) {
        Remove-Item -LiteralPath $tempLogPath -Force
    }
}
$testsPassed++

# Update-IisPoolsFromCsv_MissingCsv_ThrowsFileNotFoundError
Reset-TestState
$script:testState.CsvExists = $false
Assert-Throws {
    Update-IisPoolsFromCsv -CsvPath 'missing.csv' -CurrentServerIp '172.25.109.151' -CurrentServerName 'SVR01'
} 'Missing CSV should cause an error.'
$testsPassed++

# Set-IisAppPoolGmsa_IisProviderUnavailable_ThrowsAvailabilityError
Reset-TestState
$script:testState.IisAvailable = $false
Assert-Throws {
    Set-IisAppPoolGmsa -PoolNames 'ExamplePool' -GmsaUser 'DOMAIN\svc-example$'
} 'Unavailable IIS provider should cause an error.'
$testsPassed++

Write-Host "Passed $testsPassed PowerShell tests."
