# Autor:   Jairo Espitia
# Fecha:   2026-10-27
# Versión: 1.0

$ErrorActionPreference = 'Stop'
$productionScript = Join-Path $PSScriptRoot 'Update-Accounts.ps1'
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
        LocalAddresses = @([System.Net.IPAddress]::Parse('172.25.109.151'), [System.Net.IPAddress]::Parse('172.25.109.152'))
        MissingPath = ''
        UseRealCsv = $false
        CsvHeaders = @('Servidor', 'IP', 'Componente', 'Clasificacion')
        AccountsHeaders = @('Servidor', 'IP', 'Componente', 'CuentaGMSA')
        AccountRows = @(
            [pscustomobject]@{ Componente = 'ExamplePool'; CuentaGMSA = 'DOMAIN\svc-example$' }
            [pscustomobject]@{ Componente = 'SaveFailurePool'; CuentaGMSA = 'DOMAIN\svc-example$' }
            [pscustomobject]@{ Componente = 'RestartFailurePool'; CuentaGMSA = 'DOMAIN\svc-example$' }
        )
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

    if ($script:testState.UseRealCsv) {
        return [System.IO.File]::Exists($Path)
    }
    if ($Path -eq $script:testState.MissingPath) {
        return $false
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

    if ($script:testState.UseRealCsv) {
        return Microsoft.PowerShell.Utility\Import-Csv -Path $Path
    }
    $rows = if ($Path -eq 'accounts.csv') {
        $script:testState.AccountRows
    }
    else {
        $script:testState.CsvRows
    }
    foreach ($row in $rows) {
        if (-not $row.PSObject.Properties['Servidor']) {
            $row | Add-Member -NotePropertyName Servidor -NotePropertyValue ([System.Environment]::MachineName)
        }
        if (-not $row.PSObject.Properties['IP']) {
            $row | Add-Member -NotePropertyName IP -NotePropertyValue '172.25.109.151'
        }
    }
    return $rows
}

function Import-Module {
    param([string]$Name)
}

# Carga las funciones reales sin ejecutar el bloque principal del script.
foreach ($functionAst in $scriptAst.FindAll(
    { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },
    $false
)) {
    . ([scriptblock]::Create($functionAst.Extent.Text))
}

$script:getCsvHeadersFunction = (Get-Command Get-CsvHeaders).ScriptBlock
$script:getLocalIpAddressesFunction = (Get-Command Get-LocalIpAddresses).ScriptBlock
function Get-LocalIpAddresses {
    return $script:testState.LocalAddresses
}
# Simula el encabezado para probar la validación sin depender de archivos CSV.
function Get-CsvHeaders {
    param([string]$CsvPath)

    if ($script:testState.UseRealCsv) {
        return & $script:getCsvHeadersFunction -CsvPath $CsvPath
    }
    if ($CsvPath -eq 'accounts.csv') {
        return $script:testState.AccountsHeaders
    }
    return $script:testState.CsvHeaders
}

$PSDefaultParameterValues['Update-IisPoolsFromCsv:AccountsPath'] = 'accounts.csv'

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

# Update-IisPoolsFromCsv_MissingRequiredColumns_ThrowsValidationError
Reset-TestState
$script:testState.CsvHeaders = @('Servidor')
Assert-Throws {
    $null = Update-IisPoolsFromCsv -CsvPath 'pools.csv'
} 'A CSV missing required columns should cause an error.'
$testsPassed++

# Update-IisPoolsFromCsv_DuplicateRequiredColumns_ThrowsValidationError
Reset-TestState
$script:testState.CsvHeaders = @('Servidor', 'IP', 'Componente', 'Componente')
Assert-Throws {
    Update-IisPoolsFromCsv -CsvPath 'pools.csv'
} 'A CSV with duplicated required columns should cause an error.'
$testsPassed++

# Update-IisPoolsFromCsv_HeaderOnlyCsv_ReturnsEmptySummary
Reset-TestState
$script:testState.CsvHeaders = @('Servidor', 'IP', 'Componente')
$emptyResult = Update-IisPoolsFromCsv -CsvPath 'pools.csv'
Assert-Equal $emptyResult.TotalRows 0 'A header-only CSV should report zero rows.'
Assert-Equal $emptyResult.Updated 0 'A header-only CSV should not update pools.'
$testsPassed++

# Update-IisPoolsFromCsv_MissingComponentOrGmsa_CountsRowsAsSkipped
Reset-TestState
$script:testState.AccountRows += [pscustomobject]@{ Componente = 'MissingGmsaPool'; CuentaGMSA = ' ' }
$script:testState.CsvRows = @(
    [pscustomobject]@{
        Servidor = [System.Environment]::MachineName
        IP = '172.25.109.151'
        Clasificacion = 'IIS Pool'
        Componente = ''
        CuentaGMSA = 'DOMAIN\svc-example$'
    }
    [pscustomobject]@{
        Servidor = [System.Environment]::MachineName
        IP = '172.25.109.151'
        Clasificacion = 'IIS Pool'
        Componente = 'MissingGmsaPool'
        CuentaGMSA = ' '
    }
)
$incompleteResult = Update-IisPoolsFromCsv -CsvPath 'pools.csv'
Assert-Equal $incompleteResult.Skipped 2 'Rows with missing component or gMSA should be reported as skipped.'
Assert-Equal $incompleteResult.Updated 0 'Incomplete rows should not update pools.'
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
        Servidor = [System.Environment]::MachineName
        IP = '172.25.109.151'
        Clasificacion = 'IIS Pool'
        Componente = 'ExamplePool'
        CuentaGMSA = 'DOMAIN\svc-example$'
    }
)

$simulatedUpdate = Update-IisPoolsFromCsv -CsvPath 'pools.csv' -RestartPool -WhatIf
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
        Servidor = [System.Environment]::MachineName
        IP = '172.25.109.151'
        Clasificacion = 'IIS Pool'
        Componente = 'SaveFailurePool'
        CuentaGMSA =  'DOMAIN\svc-example$'
    }
)
$saveFailureResult = Update-IisPoolsFromCsv -CsvPath 'pools.csv' 2>$null
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
        Servidor = [System.Environment]::MachineName
        IP = '172.25.109.151'
        Clasificacion = 'IIS Pool'
        Componente = 'RestartFailurePool'
        CuentaGMSA =  'DOMAIN\svc-example$'
    }
)
$restartFailureResult = Update-IisPoolsFromCsv -CsvPath 'pools.csv' -RestartPool 2>$null
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
        Servidor = [System.Environment]::MachineName
        IP = '172.25.109.151'
        Clasificacion = 'IIS Pool'
        Componente = 'ExamplePool'
        CuentaGMSA = 'DOMAIN\svc-example$'
    }
)

$successResult = Update-IisPoolsFromCsv -CsvPath 'pools.csv' -RestartPool
Assert-Equal $script:testState.Pool.processModel.identityType 'SpecificUser' 'CSV row did not change the pool identity type.'
Assert-Equal $script:testState.Pool.processModel.userName 'DOMAIN\svc-example$' 'CSV row did not set the pool gMSA.'
Assert-Equal $script:testState.Pool.processModel.password '' 'CSV row did not clear the pool password.'
Assert-Equal $script:testState.SetItemCalls.Count 1 'CSV row did not save the pool changes exactly once.'
Assert-Equal $script:testState.RestartedPools.Count 1 'CSV row did not restart the started pool exactly once.'
Assert-Equal $successResult.Updated 1 'The summary should count a successfully updated pool.'
$testsPassed++

# Validate each input independently before attempting any changes.
Reset-TestState
$script:testState.AccountsHeaders = @('Servidor', 'IP', 'Componente')
Assert-Throws {
    Update-IisPoolsFromCsv -CsvPath 'pools.csv'
} 'A catalog missing CuentaGMSA should cause an error.'
Assert-Equal $script:testState.SetItemCalls.Count 0 'Invalid catalog headers should not update pools.'
$script:testState.AccountsHeaders = @('Servidor', 'IP', 'Componente', 'CuentaGMSA', 'CuentaGMSA')
Assert-Throws {
    Update-IisPoolsFromCsv -CsvPath 'pools.csv'
} 'A catalog with duplicate required columns should cause an error.'
$testsPassed++

# Validate server and IP columns in both inputs.
foreach ($inputName in @('CsvHeaders', 'AccountsHeaders')) {
    foreach ($missingColumn in @('Servidor', 'IP')) {
        Reset-TestState
        $script:testState[$inputName] = @($script:testState[$inputName] | Where-Object { $_ -ne $missingColumn })
        Assert-Throws {
            Update-IisPoolsFromCsv -CsvPath 'pools.csv'
        } "Missing $missingColumn in $inputName should cause an error."
        Assert-Equal $script:testState.SetItemCalls.Count 0 'Missing headers must prevent pool changes.'
    }
}
$testsPassed++

# Match the local server, IP and component before selecting the first matching catalog row.
Reset-TestState
$script:testState.Pool = [pscustomobject]@{
    processModel = [pscustomobject]@{ identityType = 'ApplicationPoolIdentity'; userName = ''; password = '' }
    State = 'Started'
}
$localServer = [System.Environment]::MachineName
$script:testState.AccountRows = @(
    [pscustomobject]@{ Servidor = 'OtherServer'; IP = '172.25.109.151'; Componente = 'ExamplePool'; CuentaGMSA = 'DOMAIN\remote$' }
    [pscustomobject]@{ Servidor = $localServer; IP = '172.25.109.152'; Componente = 'ExamplePool'; CuentaGMSA = 'DOMAIN\wrongip$' }
    [pscustomobject]@{ Servidor = $localServer.ToLowerInvariant(); IP = '172.25.109.151'; Componente = 'ExamplePool'; CuentaGMSA = 'DOMAIN\local$' }
    [pscustomobject]@{ Servidor = $localServer; IP = '172.25.109.151'; Componente = 'ExamplePool'; CuentaGMSA = 'DOMAIN\duplicate$' }
    [pscustomobject]@{ Servidor = ''; IP = '172.25.109.151'; Componente = 'InvalidCatalog'; CuentaGMSA = 'DOMAIN\invalid$' }
    [pscustomobject]@{ Servidor = $localServer; IP = ''; Componente = 'MissingCatalogIp'; CuentaGMSA = 'DOMAIN\invalid$' }
)
$script:testState.CsvRows = @(
    [pscustomobject]@{ Servidor = 'OtherServer'; IP = '172.25.109.151'; Componente = 'ExamplePool' }
    [pscustomobject]@{ Servidor = $localServer; IP = '172.25.109.153'; Componente = 'ExamplePool' }
    [pscustomobject]@{ Servidor = ''; IP = '172.25.109.151'; Componente = 'ExamplePool' }
    [pscustomobject]@{ Servidor = $localServer; IP = ''; Componente = 'ExamplePool' }
    [pscustomobject]@{ Servidor = $localServer; IP = '172.25.109.151 '; Componente = 'ExamplePool' }
    [pscustomobject]@{ Servidor = $localServer; IP = '172.25.109.151'; Componente = 'ExamplePool' }
    [pscustomobject]@{ Servidor = $localServer; IP = '172.25.109.151'; Componente = 'ExamplePool' }
)
$serverResult = Update-IisPoolsFromCsv -CsvPath 'pools.csv' -RestartPool 3>$null
Assert-Equal $serverResult.Updated 1 'Only the local matching component should be updated.'
Assert-Equal $serverResult.Skipped 6 'Nonlocal, unmatched, incomplete and duplicate inventory rows should be skipped.'
Assert-Equal $script:testState.Pool.processModel.userName 'DOMAIN\local$' 'The first matching server and IP account should be used.'
Assert-Equal $script:testState.SetItemCalls.Count 1 'Only one identity change should be saved.'
Assert-Equal $script:testState.RestartedPools.Count 1 'Only one restart should occur.'
Assert-Equal @($serverResult.Changes | Where-Object { $_.Status -eq 'Skipped' }).Count 10 'All skipped catalog and inventory rows should be included in the log entries.'
if (-not @($serverResult.Changes | Where-Object { $_.Message -like '*no coincide con el servidor local*' }).Count) {
    throw 'The skipped remote server should be identifiable in the log.'
}
$testsPassed++

# Validate both CSVs against local IPv4 and IPv6 addresses before touching IIS.
Reset-TestState
$script:testState.LocalAddresses = @([System.Net.IPAddress]::Parse('192.0.2.1'), [System.Net.IPAddress]::Parse('2001:db8::1'))
$script:testState.Pool = [pscustomobject]@{
    processModel = [pscustomobject]@{ identityType = 'ApplicationPoolIdentity'; userName = ''; password = '' }
    State = 'Started'
}
$localServer = [System.Environment]::MachineName
$script:testState.AccountRows = @(
    [pscustomobject]@{ Servidor = $localServer; IP = '192.0.2.99'; Componente = 'RemoteIp'; CuentaGMSA = 'DOMAIN\remote$' }
    [pscustomobject]@{ Servidor = $localServer; IP = 'invalid'; Componente = 'InvalidIp'; CuentaGMSA = 'DOMAIN\invalid$' }
    [pscustomobject]@{ Servidor = $localServer; IP = '2001:db8::1'; Componente = 'ExamplePool'; CuentaGMSA = 'DOMAIN\local$' }
)
$script:testState.CsvRows = @(
    [pscustomobject]@{ Servidor = $localServer; IP = '192.0.2.99'; Componente = 'RemoteIp' }
    [pscustomobject]@{ Servidor = $localServer; IP = 'invalid'; Componente = 'InvalidIp' }
    [pscustomobject]@{ Servidor = $localServer; IP = '192.0.2.1 '; Componente = 'ExamplePool' }
    [pscustomobject]@{ Servidor = 'OtherServer'; IP = '2001:db8::1'; Componente = 'ExamplePool' }
    [pscustomobject]@{ Servidor = $localServer; IP = '2001:db8::1'; Componente = 'ExamplePool' }
)
$localIpResult = Update-IisPoolsFromCsv -CsvPath 'pools.csv' -RestartPool 3>$null
Assert-Equal $localIpResult.Updated 1 'Only the row matching a local server and IP should update.'
Assert-Equal $localIpResult.Skipped 4 'Invalid and nonlocal inventory rows should be skipped.'
Assert-Equal @($localIpResult.Changes | Where-Object { $_.Status -eq 'Skipped' }).Count 6 'Nonlocal catalog rows and invalid inventory rows must be logged.'
Assert-Equal $script:testState.Pool.processModel.userName 'DOMAIN\local$' 'The local IPv6 account should be applied.'
Assert-Equal $script:testState.SetItemCalls.Count 1 'Nonlocal rows must not save any pool.'
Assert-Equal $script:testState.RestartedPools.Count 1 'Nonlocal rows must not restart any pool.'
Assert-Equal (Test-LocalIpAddress -Address '192.0.2.1' -LocalAddresses $script:testState.LocalAddresses) $true 'The first local IPv4 address should match.'
Assert-Equal (Test-LocalIpAddress -Address '2001:db8:0:0:0:0:0:1' -LocalAddresses $script:testState.LocalAddresses) $true 'Equivalent IPv6 addresses should match local interfaces.'
$localIpLogPath = [System.IO.Path]::GetTempFileName()
try {
    Remove-Item -LiteralPath $localIpLogPath -Force
    foreach ($change in $localIpResult.Changes) {
        Write-IisChangeLog -Path $localIpLogPath -Entry $change
    }
    $localIpLog = @(Microsoft.PowerShell.Utility\Import-Csv -Path $localIpLogPath)
    Assert-Equal @($localIpLog | Where-Object { $_.Status -eq 'Skipped' -and $_.Message -like '*no está asignada al equipo local*' }).Count 5 'Invalid and nonlocal IPs should be recorded in the CSV log.'
}
finally {
    if ([System.IO.File]::Exists($localIpLogPath)) {
        Remove-Item -LiteralPath $localIpLogPath -Force
    }
}
$testsPassed++

# Missing local address data must fail before any pool is changed.
Reset-TestState
$script:testState.LocalAddresses = @()
Assert-Throws {
    Update-IisPoolsFromCsv -CsvPath 'pools.csv'
} 'Missing local addresses must fail explicitly.'
Assert-Equal $script:testState.SetItemCalls.Count 0 'Missing local addresses must prevent changes.'
$testsPassed++

# The catalog is authoritative, with exact matches and first duplicate winning.
Reset-TestState
$script:testState.Pool = [pscustomobject]@{
    processModel = [pscustomobject]@{ identityType = 'ApplicationPoolIdentity'; userName = ''; password = '' }
    State = 'Started'
}
$script:testState.AccountRows = @(
    [pscustomobject]@{ Componente = 'ExamplePool'; CuentaGMSA = 'DOMAIN\first$' }
    [pscustomobject]@{ Componente = 'ExamplePool'; CuentaGMSA = 'DOMAIN\second$' }
    [pscustomobject]@{ Componente = 'InvalidPool'; CuentaGMSA = 'DOMAIN\not-gmsa' }
    [pscustomobject]@{ Componente = ''; CuentaGMSA = 'DOMAIN\orphan$' }
)
$script:testState.CsvRows = @(
    [pscustomobject]@{ Componente = 'examplepool'; CuentaGMSA = 'DOMAIN\legacy$' }
    [pscustomobject]@{ Componente = 'ExamplePool'; CuentaGMSA = 'DOMAIN\legacy$' }
    [pscustomobject]@{ Componente = 'ExamplePool'; CuentaGMSA = 'DOMAIN\legacy$' }
    [pscustomobject]@{ Componente = ' ExamplePool'; CuentaGMSA = 'DOMAIN\legacy$' }
    [pscustomobject]@{ Componente = 'InvalidPool'; CuentaGMSA = 'DOMAIN\legacy$' }
    [pscustomobject]@{ Componente = 'NoMatch'; CuentaGMSA = 'DOMAIN\legacy$' }
)
$joinedResult = Update-IisPoolsFromCsv -CsvPath 'pools.csv' -RestartPool 3>$null
Assert-Equal $joinedResult.TotalRows 6 'The inventory row count should not include catalog rows.'
Assert-Equal $joinedResult.Updated 1 'Only the exact match should update a pool.'
Assert-Equal $joinedResult.Skipped 5 'Invalid, duplicate and unmatched inventory rows should be skipped.'
Assert-Equal $script:testState.Pool.processModel.userName 'DOMAIN\first$' 'The first catalog account must override the legacy inventory account.'
Assert-Equal $script:testState.SetItemCalls.Count 1 'A pool should be saved only once.'
Assert-Equal $script:testState.RestartedPools.Count 1 'A pool should be restarted only once.'
Assert-Equal @($joinedResult.Changes | Where-Object { $_.Status -eq 'Skipped' }).Count 8 'Skipped inventory and catalog rows must be logged.'
$testsPassed++

# An empty first catalog account must not be replaced by a later duplicate.
Reset-TestState
$script:testState.AccountRows = @(
    [pscustomobject]@{ Componente = 'ExamplePool'; CuentaGMSA = '' }
    [pscustomobject]@{ Componente = 'ExamplePool'; CuentaGMSA = 'DOMAIN\second$' }
)
$script:testState.CsvRows = @([pscustomobject]@{ Componente = 'ExamplePool' })
$firstEmptyResult = Update-IisPoolsFromCsv -CsvPath 'pools.csv' 3>$null
Assert-Equal $firstEmptyResult.Skipped 1 'An empty first account should cause the inventory row to be skipped.'
Assert-Equal $script:testState.SetItemCalls.Count 0 'A later duplicate must not replace an empty first account.'
$testsPassed++

# Differently cased catalog entries must not cause the same IIS pool to be changed twice.
Reset-TestState
$script:testState.Pool = [pscustomobject]@{
    processModel = [pscustomobject]@{ identityType = 'ApplicationPoolIdentity'; userName = ''; password = '' }
    State = 'Started'
}
$script:testState.AccountRows = @(
    [pscustomobject]@{ Componente = 'ExamplePool'; CuentaGMSA = 'DOMAIN\first$' }
    [pscustomobject]@{ Componente = 'examplepool'; CuentaGMSA = 'DOMAIN\second$' }
)
$script:testState.CsvRows = @(
    [pscustomobject]@{ Componente = 'ExamplePool' }
    [pscustomobject]@{ Componente = 'examplepool' }
)
$caseDuplicateResult = Update-IisPoolsFromCsv -CsvPath 'pools.csv' -RestartPool 3>$null
Assert-Equal $caseDuplicateResult.Updated 1 'The same case-insensitive IIS pool should be updated once.'
Assert-Equal $caseDuplicateResult.Skipped 1 'The second case variant should be skipped.'
Assert-Equal $script:testState.Pool.processModel.userName 'DOMAIN\first$' 'The second case variant must not overwrite the account.'
Assert-Equal $script:testState.RestartedPools.Count 1 'Case variants must not restart the same pool twice.'
$testsPassed++

# Both CSV files are mandatory.
Reset-TestState
$script:testState.MissingPath = 'accounts.csv'
Assert-Throws {
    Update-IisPoolsFromCsv -CsvPath 'pools.csv'
} 'A missing catalog should cause an error.'
Assert-Equal $script:testState.SetItemCalls.Count 0 'A missing catalog should not update pools.'
$testsPassed++

# Exercise real CSV parsing and logging with both files and an obsolete inventory column.
Reset-TestState
$script:testState.UseRealCsv = $true
$script:testState.Pool = [pscustomobject]@{
    processModel = [pscustomobject]@{ identityType = 'ApplicationPoolIdentity'; userName = ''; password = '' }
    State = 'Stopped'
}
$inventoryPath = [System.IO.Path]::GetTempFileName()
$catalogPath = [System.IO.Path]::GetTempFileName()
$integrationLogPath = [System.IO.Path]::GetTempFileName()
try {
    $localServer = [System.Environment]::MachineName
    Set-Content -LiteralPath $inventoryPath -Value @('Servidor,IP,Componente,CuentaGMSA', "$localServer,172.25.109.151,ExamplePool,DOMAIN\legacy`$", "$localServer,172.25.109.151,NoMatch,DOMAIN\legacy`$")
    Set-Content -LiteralPath $catalogPath -Value @('Servidor,IP,Componente,CuentaGMSA', "$localServer,172.25.109.151,ExamplePool,DOMAIN\catalog`$")
    Remove-Item -LiteralPath $integrationLogPath -Force
    $realResult = Update-IisPoolsFromCsv -CsvPath $inventoryPath -AccountsPath $catalogPath 3>$null
    foreach ($change in $realResult.Changes) {
        Write-IisChangeLog -Path $integrationLogPath -Entry $change
    }
    $logged = @(Microsoft.PowerShell.Utility\Import-Csv -Path $integrationLogPath)
    Assert-Equal $script:testState.Pool.processModel.userName 'DOMAIN\catalog$' 'Real CSV join should use the catalog account.'
    Assert-Equal $logged.Count 2 'Both updated and skipped inventory rows should be written to the log.'
    Assert-Equal $logged[1].Status 'Skipped' 'The unmatched component should be recorded as skipped.'
}
finally {
    Remove-Item -LiteralPath $inventoryPath, $catalogPath, $integrationLogPath -Force -ErrorAction SilentlyContinue
}
$testsPassed++

# Exercise the script entry point with default, relative and absolute catalog paths.
Reset-TestState
$script:testState.UseRealCsv = $true
$script:testState.Pool = [pscustomobject]@{
    processModel = [pscustomobject]@{ identityType = 'ApplicationPoolIdentity'; userName = ''; password = '' }
    State = 'Started'
}
$testDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
$testScript = Join-Path $testDirectory 'Update-Accounts.ps1'
$testInventory = Join-Path $testDirectory 'inventory.csv'
$defaultCatalog = Join-Path $testDirectory 'cuentas_gmsa_aprobadas.csv'
$alternateCatalog = Join-Path $testDirectory 'alternate.csv'
$entryLog = Join-Path $testDirectory 'changes.csv'
try {
    $null = New-Item -ItemType Directory -Path $testDirectory
    Copy-Item -LiteralPath $productionScript -Destination $testScript
    $localServer = [System.Environment]::MachineName
    $realLocalAddresses = @(& $script:getLocalIpAddressesFunction)
    if ($realLocalAddresses.Count -eq 0) {
        throw 'The integration test requires at least one local IP address.'
    }
    $realLocalIp = $realLocalAddresses[0].ToString()
    Set-Content -LiteralPath $testInventory -Value @('Servidor,IP,Componente', "$localServer,$realLocalIp,ExamplePool")
    Set-Content -LiteralPath $defaultCatalog -Value @('Servidor,IP,Componente,CuentaGMSA', "$localServer,$realLocalIp,ExamplePool,DOMAIN\default`$")
    Set-Content -LiteralPath $alternateCatalog -Value @('Servidor,IP,Componente,CuentaGMSA', "$localServer,$realLocalIp,ExamplePool,DOMAIN\alternate`$")

    Push-Location ([System.IO.Path]::GetTempPath())
    try {
        $defaultOutput = @(. $testScript -AuditoriaPath 'inventory.csv' -LogPath $entryLog -WhatIf 6>&1)
        $relativeOutput = @(. $testScript -AuditoriaPath 'inventory.csv' -CatalogoGmsaPath 'alternate.csv' -LogPath $entryLog -WhatIf 6>&1)
        $absoluteOutput = @(. $testScript -AuditoriaPath 'inventory.csv' -CatalogoGmsaPath $alternateCatalog -LogPath $entryLog -WhatIf 6>&1)
        $legacyOutput = @(. $testScript -CsvPath 'inventory.csv' -AccountsPath 'alternate.csv' -LogPath $entryLog -WhatIf 6>&1)
        Assert-Throws {
            . $testScript -AuditoriaPath 'inventory.csv' -CatalogoGmsaPath 'missing.csv' -LogPath $entryLog -WhatIf
        } 'A missing catalog supplied to the script should fail.'
    }
    finally {
        Pop-Location
    }

    $entries = @(Microsoft.PowerShell.Utility\Import-Csv -Path $entryLog)
    Assert-Equal $entries.Count 4 'All successful simulations should each be logged.'
    Assert-Equal $entries[0].GmsaUser 'DOMAIN\default$' 'The default catalog should be selected.'
    Assert-Equal $entries[1].GmsaUser 'DOMAIN\alternate$' 'The relative catalog should be selected.'
    Assert-Equal $entries[2].GmsaUser 'DOMAIN\alternate$' 'The absolute catalog should be selected.'
    Assert-Equal $entries[3].GmsaUser 'DOMAIN\alternate$' 'The legacy parameter aliases should select the alternate catalog.'
    if (-not ($entries[0].Message.Contains($defaultCatalog) -and $entries[1].Message.Contains($alternateCatalog) -and $entries[2].Message.Contains($alternateCatalog) -and $entries[3].Message.Contains($alternateCatalog))) {
        throw 'Each log entry should identify the resolved catalog path.'
    }
    if (-not (($defaultOutput -join "`n").Contains($defaultCatalog) -and ($relativeOutput -join "`n").Contains($alternateCatalog) -and ($absoluteOutput -join "`n").Contains($alternateCatalog) -and ($legacyOutput -join "`n").Contains($alternateCatalog))) {
        throw 'The script should display each resolved catalog path.'
    }
    Assert-Equal $script:testState.SetItemCalls.Count 0 'Script simulations should not save pool settings.'
    Assert-Equal $script:testState.RestartedPools.Count 0 'Script simulations should not restart pools.'
}
finally {
    foreach ($path in @($testScript, $testInventory, $defaultCatalog, $alternateCatalog, $entryLog)) {
        if ([System.IO.File]::Exists($path)) {
            Remove-Item -LiteralPath $path -Force
        }
    }
    if ([System.IO.Directory]::Exists($testDirectory)) {
        Remove-Item -LiteralPath $testDirectory -Force
    }
}
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
    Update-IisPoolsFromCsv -CsvPath 'missing.csv'
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
