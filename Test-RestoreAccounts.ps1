$ErrorActionPreference = 'Stop'
$productionScript = Join-Path $PSScriptRoot 'Restore-Accounts.ps1'
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
        CsvHeaders = @('Servidor', 'IP', 'Componente', 'Clasificacion', 'CuentaActual')
        Pool = $null
        CsvRows = @()
        Passwords = @{}
        ConfirmPasswords = @{}
        PromptedAccounts = @()
        FailSetItem = $false
        FailRestart = $false
        SetItemCalls = @()
        SavedSettings = @()
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
        $script:testState.SavedSettings += [pscustomobject]@{
            UserName = $InputObject.processModel.userName
            Password = $InputObject.processModel.password
        }
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

# Simula la solicitud interactiva de contraseñas.
function Read-Host {
    param(
        [string]$Prompt,
        [switch]$AsSecureString
    )

    $account = $null
    if ($Prompt -match "cuenta '(.+)'") {
        $account = $Matches[1]
        $script:testState.PromptedAccounts += $account
    }

    $plainPassword = 'simulated-password'
    if ($null -ne $account -and $script:testState.Passwords.ContainsKey($account)) {
        $plainPassword = $script:testState.Passwords[$account]
    }
    if ($Prompt -like 'Confirmar *' -and
        $null -ne $account -and
        $script:testState.ConfirmPasswords.ContainsKey($account)) {
        $plainPassword = $script:testState.ConfirmPasswords[$account]
    }

    $securePassword = [System.Security.SecureString]::new()
    foreach ($char in $plainPassword.ToCharArray()) {
        $securePassword.AppendChar($char)
    }
    $securePassword.MakeReadOnly()
    return $securePassword
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

# Set-IisAppPoolAccount_StartedPoolWithRestart_UpdatesIdentityAndRestartsPool
Reset-TestState
$script:testState.Pool = [pscustomobject]@{
    processModel = [pscustomobject]@{
        identityType = 'SpecificUser'
        userName = 'DOMAIN\svc-gmsa$'
        password = ''
    }
    State = 'Started'
}

$null = Set-IisAppPoolAccount -PoolNames 'ExamplePool' -UserName 'DOMAIN\svc-example' -Password 'secret' -RestartPool
Assert-Equal $script:testState.Pool.processModel.identityType 'SpecificUser' 'Pool identity type was not updated.'
Assert-Equal $script:testState.Pool.processModel.userName 'DOMAIN\svc-example' 'Pool account was not updated.'
Assert-Equal $script:testState.Pool.processModel.password 'secret' 'Pool password was not updated.'
Assert-Equal $script:testState.SetItemCalls.Count 1 'Pool settings were not saved exactly once.'
Assert-Equal $script:testState.RestartedPools.Count 1 'Started pool was not restarted exactly once.'
$testsPassed++

# Set-IisAppPoolAccount_WhatIf_DoesNotSaveOrRestartPool
Reset-TestState
$script:testState.Pool = [pscustomobject]@{
    processModel = [pscustomobject]@{
        identityType = 'SpecificUser'
        userName = 'DOMAIN\svc-gmsa$'
        password = ''
    }
    State = 'Started'
}

$whatIfResult = Set-IisAppPoolAccount -PoolNames 'ExamplePool' -UserName 'DOMAIN\svc-example' -Password 'secret' -RestartPool -WhatIf
Assert-Equal $whatIfResult.Status 'WhatIf' 'WhatIf should report a simulated change.'
Assert-Equal $script:testState.Pool.processModel.userName 'DOMAIN\svc-gmsa$' 'WhatIf should not change the pool identity.'
Assert-Equal $script:testState.SetItemCalls.Count 0 'WhatIf should not save pool settings.'
Assert-Equal $script:testState.RestartedPools.Count 0 'WhatIf should not restart the pool.'
$testsPassed++

# Set-IisAppPoolAccount_StoppedPoolWithRestart_UpdatesIdentityWithoutRestarting
Reset-TestState
$script:testState.Pool = [pscustomobject]@{
    processModel = [pscustomobject]@{
        identityType = 'SpecificUser'
        userName = 'DOMAIN\svc-gmsa$'
        password = ''
    }
    State = 'Stopped'
}

$null = Set-IisAppPoolAccount -PoolNames 'StoppedPool' -UserName 'DOMAIN\svc-example' -Password 'secret' -RestartPool
Assert-Equal $script:testState.RestartedPools.Count 0 'Stopped pool should not be restarted.'
$testsPassed++

# Set-IisAppPoolAccount_MissingPool_SkipsPoolWithoutSaving
Reset-TestState
$script:testState.PoolExists = $false
$null = Set-IisAppPoolAccount -PoolNames 'MissingPool' -UserName 'DOMAIN\svc-example' -Password 'secret'
Assert-Equal $script:testState.SetItemCalls.Count 0 'A missing pool should not be changed.'
$testsPassed++

# Restore-IisPoolsFromCsv_MissingRequiredColumns_ThrowsValidationError
Reset-TestState
$script:testState.CsvHeaders = @('Componente')
Assert-Throws {
    $null = Restore-IisPoolsFromCsv -CsvPath 'pools.csv'
} 'A CSV missing required columns should cause an error.'
$testsPassed++

# Restore-IisPoolsFromCsv_DuplicateRequiredColumns_ThrowsValidationError
Reset-TestState
$script:testState.CsvHeaders = @('Componente', 'CuentaActual', 'CuentaActual')
Assert-Throws {
    Restore-IisPoolsFromCsv -CsvPath 'pools.csv'
} 'A CSV with duplicated required columns should cause an error.'
$testsPassed++

# Restore-IisPoolsFromCsv_HeaderOnlyCsv_ReturnsEmptySummary
Reset-TestState
$script:testState.CsvHeaders = @('Componente', 'CuentaActual')
$emptyResult = Restore-IisPoolsFromCsv -CsvPath 'pools.csv'
Assert-Equal $emptyResult.TotalRows 0 'A header-only CSV should report zero rows.'
Assert-Equal $emptyResult.Updated 0 'A header-only CSV should not update pools.'
$testsPassed++

# Restore-IisPoolsFromCsv_MissingComponentOrAccount_CountsRowsAsSkipped
Reset-TestState
$script:testState.CsvRows = @(
    [pscustomobject]@{
        Servidor = 'SVR01'
        IP = '172.25.109.151'
        Clasificacion = 'IIS Pool'
        Componente = ''
        CuentaActual = 'DOMAIN\svc-example'
    }
    [pscustomobject]@{
        Servidor = 'SVR01'
        IP = '172.25.109.151'
        Clasificacion = 'IIS Pool'
        Componente = 'MissingAccountPool'
        CuentaActual = ' '
    }
)
$incompleteResult = Restore-IisPoolsFromCsv -CsvPath 'pools.csv'
Assert-Equal $incompleteResult.Skipped 2 'Rows with missing component or account should be reported as skipped.'
Assert-Equal $incompleteResult.Updated 0 'Incomplete rows should not update pools.'
$testsPassed++

# Restore-IisPoolsFromCsv_WhatIf_ReportsSimulationWithoutSavingOrPrompting
Reset-TestState
$script:testState.Pool = [pscustomobject]@{
    processModel = [pscustomobject]@{
        identityType = 'SpecificUser'
        userName = 'DOMAIN\svc-gmsa$'
        password = ''
    }
    State = 'Started'
}
$script:testState.CsvRows = @(
    [pscustomobject]@{
        Servidor = 'SVR01'
        IP = '172.25.109.151'
        Clasificacion = 'IIS Pool'
        Componente = 'ExamplePool'
        CuentaActual = 'DOMAIN\svc-example'
    }
)

$simulatedUpdate = Restore-IisPoolsFromCsv -CsvPath 'pools.csv' -RestartPool -WhatIf
Assert-Equal $simulatedUpdate.WhatIf 1 'The summary should count the simulated pool change.'
Assert-Equal $simulatedUpdate.Updated 0 'A simulated change should not count as an update.'
Assert-Equal $simulatedUpdate.Changes[0].Status 'WhatIf' 'The change details should identify the simulated action.'
Assert-Equal $script:testState.Pool.processModel.userName 'DOMAIN\svc-gmsa$' 'The restore command should not change the pool during WhatIf.'
Assert-Equal $script:testState.SetItemCalls.Count 0 'The restore command should not save pool settings during WhatIf.'
Assert-Equal $script:testState.RestartedPools.Count 0 'The restore command should not restart pools during WhatIf.'
Assert-Equal $script:testState.PromptedAccounts.Count 0 'WhatIf should not prompt for passwords.'
$testsPassed++

# Restore-IisPoolsFromCsv_SaveFailure_CountsFailureAndIncludesErrorDetails
Reset-TestState
$script:testState.Pool = [pscustomobject]@{
    processModel = [pscustomobject]@{
        identityType = 'SpecificUser'
        userName = 'DOMAIN\svc-gmsa$'
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
        CuentaActual = 'DOMAIN\svc-example'
    }
)
$saveFailureResult = Restore-IisPoolsFromCsv -CsvPath 'pools.csv' 2>$null
Assert-Equal $saveFailureResult.Failed 1 'A save failure should be counted.'
Assert-Equal $saveFailureResult.Errors.Count 1 'A save failure should include error details.'
if ($saveFailureResult.Errors[0] -notlike '*Simulated save failure*') {
    throw 'The save failure summary did not include its cause.'
}
$testsPassed++

# Restore-IisPoolsFromCsv_RestartFailure_CountsFailureAndPreservesSavedSettings
Reset-TestState
$script:testState.Pool = [pscustomobject]@{
    processModel = [pscustomobject]@{
        identityType = 'SpecificUser'
        userName = 'DOMAIN\svc-gmsa$'
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
        CuentaActual = 'DOMAIN\svc-example'
    }
)
$restartFailureResult = Restore-IisPoolsFromCsv -CsvPath 'pools.csv' -RestartPool 2>$null
Assert-Equal $restartFailureResult.Failed 1 'A restart failure should be counted.'
Assert-Equal $restartFailureResult.Errors.Count 1 'A restart failure should include error details.'
Assert-Equal $script:testState.SetItemCalls.Count 1 'Pool settings should be saved before reporting a restart failure.'
if ($restartFailureResult.Errors[0] -notlike '*falló el reinicio*') {
    throw 'The restart failure summary should distinguish a restart failure.'
}
$testsPassed++

# Restore-IisPoolsFromCsv_TraditionalAccountRow_UpdatesPoolWithPromptedPassword
Reset-TestState
$script:testState.Pool = [pscustomobject]@{
    processModel = [pscustomobject]@{
        identityType = 'SpecificUser'
        userName = 'DOMAIN\svc-gmsa$'
        password = ''
    }
    State = 'Started'
}
$script:testState.CsvRows = @(
    [pscustomobject]@{
        Servidor = 'SVR01'
        IP = '172.25.109.151'
        Clasificacion = 'IIS Pool'
        Componente = 'ExamplePool'
        CuentaActual = 'DOMAIN\svc-example'
    }
)

$successResult = Restore-IisPoolsFromCsv -CsvPath 'pools.csv' -RestartPool
Assert-Equal $script:testState.Pool.processModel.identityType 'SpecificUser' 'CSV row did not change the pool identity type.'
Assert-Equal $script:testState.Pool.processModel.userName 'DOMAIN\svc-example' 'CSV row did not set the pool account.'
Assert-Equal $script:testState.Pool.processModel.password 'simulated-password' 'CSV row did not set the prompted password.'
Assert-Equal $script:testState.SetItemCalls.Count 1 'CSV row did not save the pool changes exactly once.'
Assert-Equal $script:testState.RestartedPools.Count 1 'CSV row did not restart the started pool exactly once.'
Assert-Equal $script:testState.PromptedAccounts.Count 2 'A traditional account should prompt twice to confirm its password.'
Assert-Equal $script:testState.PromptedAccounts[0] 'DOMAIN\svc-example' 'The password prompt should identify the traditional account.'
Assert-Equal $script:testState.PromptedAccounts[1] 'DOMAIN\svc-example' 'The confirmation prompt should identify the traditional account.'
Assert-Equal $successResult.Updated 1 'The summary should count a successfully updated pool.'
$testsPassed++

# Restore-IisPoolsFromCsv_RepeatedTraditionalAccount_PromptsOnceAndUpdatesEveryPool
Reset-TestState
$script:testState.Pool = [pscustomobject]@{
    processModel = [pscustomobject]@{
        identityType = 'SpecificUser'
        userName = 'DOMAIN\svc-old'
        password = 'old-password'
    }
    State = 'Started'
}
$script:testState.Passwords['DOMAIN\svc-shared'] = 'shared-password'
$script:testState.CsvRows = @(
    [pscustomobject]@{
        Componente = 'FirstPool'
        CuentaActual = 'DOMAIN\svc-shared'
    }
    [pscustomobject]@{
        Componente = 'SecondPool'
        CuentaActual = 'DOMAIN\svc-shared'
    }
)

$repeatedAccountResult = Restore-IisPoolsFromCsv -CsvPath 'pools.csv'
Assert-Equal $script:testState.PromptedAccounts.Count 2 'The same traditional account should have one password prompt and one confirmation prompt.'
Assert-Equal $script:testState.PromptedAccounts[0] 'DOMAIN\svc-shared' 'The repeated account prompt should identify the account.'
Assert-Equal $script:testState.PromptedAccounts[1] 'DOMAIN\svc-shared' 'The repeated account confirmation should identify the account.'
Assert-Equal $script:testState.SavedSettings.Count 2 'Both pools using the repeated account should be saved.'
Assert-Equal $script:testState.SavedSettings[0].UserName 'DOMAIN\svc-shared' 'The first pool should use the repeated account.'
Assert-Equal $script:testState.SavedSettings[0].Password 'shared-password' 'The first pool should use the repeated account password.'
Assert-Equal $script:testState.SavedSettings[1].UserName 'DOMAIN\svc-shared' 'The second pool should use the repeated account.'
Assert-Equal $script:testState.SavedSettings[1].Password 'shared-password' 'The second pool should use the repeated account password.'
Assert-Equal $repeatedAccountResult.Updated 2 'Both pools should be counted as updated.'
$testsPassed++

# Restore-IisPoolsFromCsv_DistinctTraditionalAccounts_PromptsOncePerAccountAndUsesMatchingPasswords
Reset-TestState
$script:testState.Pool = [pscustomobject]@{
    processModel = [pscustomobject]@{
        identityType = 'SpecificUser'
        userName = 'DOMAIN\svc-old'
        password = 'old-password'
    }
    State = 'Started'
}
$script:testState.Passwords['DOMAIN\svc-alpha'] = 'alpha-password'
$script:testState.Passwords['DOMAIN\svc-beta'] = 'beta-password'
$script:testState.CsvRows = @(
    [pscustomobject]@{
        Componente = 'AlphaPool'
        CuentaActual = 'DOMAIN\svc-alpha'
    }
    [pscustomobject]@{
        Componente = 'BetaPool'
        CuentaActual = 'DOMAIN\svc-beta'
    }
)

$distinctAccountsResult = Restore-IisPoolsFromCsv -CsvPath 'pools.csv'
Assert-Equal $script:testState.PromptedAccounts.Count 4 'Each distinct traditional account should have a password prompt and a confirmation prompt.'
if ($script:testState.PromptedAccounts -notcontains 'DOMAIN\svc-alpha' -or
    $script:testState.PromptedAccounts -notcontains 'DOMAIN\svc-beta' -or
    @($script:testState.PromptedAccounts | Where-Object { $_ -eq 'DOMAIN\svc-alpha' }).Count -ne 2 -or
    @($script:testState.PromptedAccounts | Where-Object { $_ -eq 'DOMAIN\svc-beta' }).Count -ne 2) {
    throw 'The password and confirmation prompts did not cover both distinct traditional accounts exactly once each.'
}
Assert-Equal $script:testState.SavedSettings.Count 2 'Both pools with distinct accounts should be saved.'
Assert-Equal $script:testState.SavedSettings[0].UserName 'DOMAIN\svc-alpha' 'The first pool should use the matching account.'
Assert-Equal $script:testState.SavedSettings[0].Password 'alpha-password' 'The first pool should use the matching password.'
Assert-Equal $script:testState.SavedSettings[1].UserName 'DOMAIN\svc-beta' 'The second pool should use the matching account.'
Assert-Equal $script:testState.SavedSettings[1].Password 'beta-password' 'The second pool should use the matching password.'
Assert-Equal $distinctAccountsResult.Updated 2 'Both distinct-account pools should be counted as updated.'
$testsPassed++

# Restore-IisPoolsFromCsv_MixedTraditionalAndGmsa_PromptsOnlyForTraditionalAccount
Reset-TestState
$script:testState.Pool = [pscustomobject]@{
    processModel = [pscustomobject]@{
        identityType = 'SpecificUser'
        userName = 'DOMAIN\svc-old'
        password = 'old-password'
    }
    State = 'Started'
}
$script:testState.Passwords['DOMAIN\svc-traditional'] = 'traditional-password'
$script:testState.CsvRows = @(
    [pscustomobject]@{
        Componente = 'TraditionalPool'
        CuentaActual = 'DOMAIN\svc-traditional'
    }
    [pscustomobject]@{
        Componente = 'GmsaPool'
        CuentaActual = 'DOMAIN\svc-gmsa$'
    }
)

$mixedAccountsResult = Restore-IisPoolsFromCsv -CsvPath 'pools.csv'
Assert-Equal $script:testState.PromptedAccounts.Count 2 'A mixed account list should prompt twice only for the traditional account.'
Assert-Equal $script:testState.PromptedAccounts[0] 'DOMAIN\svc-traditional' 'The gMSA account should not be prompted for.'
Assert-Equal $script:testState.PromptedAccounts[1] 'DOMAIN\svc-traditional' 'The gMSA account should not have a confirmation prompt.'
Assert-Equal $script:testState.SavedSettings.Count 2 'Both the traditional and gMSA pools should be saved.'
$traditionalSettings = @($script:testState.SavedSettings | Where-Object { $_.UserName -eq 'DOMAIN\svc-traditional' })
$gmsaSettings = @($script:testState.SavedSettings | Where-Object { $_.UserName -eq 'DOMAIN\svc-gmsa$' })
Assert-Equal $traditionalSettings.Count 1 'The traditional pool should be restored exactly once.'
Assert-Equal $traditionalSettings[0].Password 'traditional-password' 'The traditional pool should use its prompted password.'
Assert-Equal $gmsaSettings.Count 1 'The gMSA pool should be restored exactly once.'
Assert-Equal $gmsaSettings[0].Password '' 'The gMSA pool should use a blank password.'
Assert-Equal $mixedAccountsResult.Updated 2 'Both pools in the mixed list should be counted as updated.'
$testsPassed++

# Restore-IisPoolsFromCsv_GmsaRow_UpdatesPoolWithBlankPasswordWithoutPrompting
Reset-TestState
$script:testState.Pool = [pscustomobject]@{
    processModel = [pscustomobject]@{
        identityType = 'SpecificUser'
        userName = 'DOMAIN\svc-example'
        password = 'old-password'
    }
    State = 'Started'
}
$script:testState.CsvRows = @(
    [pscustomobject]@{
        Servidor = 'SVR01'
        IP = '172.25.109.151'
        Clasificacion = 'IIS Pool'
        Componente = 'GmsaPool'
        CuentaActual = 'DOMAIN\svc-gmsa$'
    }
)

$gmsaResult = Restore-IisPoolsFromCsv -CsvPath 'pools.csv' -RestartPool
Assert-Equal $script:testState.Pool.processModel.userName 'DOMAIN\svc-gmsa$' 'CSV row did not set the pool gMSA.'
Assert-Equal $script:testState.Pool.processModel.password '' 'A gMSA row should clear the pool password.'
Assert-Equal $script:testState.PromptedAccounts.Count 0 'A gMSA account should not prompt for a password.'
Assert-Equal $gmsaResult.Updated 1 'The summary should count a successfully updated gMSA pool.'
$testsPassed++

# Restore-IisPoolsFromCsv_EmptyPromptedPassword_SkipsRowWithoutSaving
Reset-TestState
$script:testState.Pool = [pscustomobject]@{
    processModel = [pscustomobject]@{
        identityType = 'SpecificUser'
        userName = 'DOMAIN\svc-gmsa$'
        password = ''
    }
    State = 'Started'
}
$script:testState.Passwords['DOMAIN\svc-example'] = ''
$script:testState.CsvRows = @(
    [pscustomobject]@{
        Servidor = 'SVR01'
        IP = '172.25.109.151'
        Clasificacion = 'IIS Pool'
        Componente = 'EmptyPasswordPool'
        CuentaActual = 'DOMAIN\svc-example'
    }
)

$emptyPasswordResult = Restore-IisPoolsFromCsv -CsvPath 'pools.csv' -RestartPool
Assert-Equal $emptyPasswordResult.Skipped 1 'A row without a prompted password should be reported as skipped.'
Assert-Equal $emptyPasswordResult.Updated 0 'A row without a prompted password should not update pools.'
Assert-Equal $script:testState.SetItemCalls.Count 0 'A row without a prompted password should not save pool settings.'
Assert-Equal $script:testState.PromptedAccounts.Count 2 'An empty password should still be confirmed before the row is skipped.'
$testsPassed++

# Restore-IisPoolsFromCsv_MismatchedPasswordConfirmation_SkipsRowsWithoutSaving
Reset-TestState
$script:testState.Pool = [pscustomobject]@{
    processModel = [pscustomobject]@{
        identityType = 'SpecificUser'
        userName = 'DOMAIN\svc-old'
        password = 'old-password'
    }
    State = 'Started'
}
$script:testState.Passwords['DOMAIN\svc-example'] = 'first-password'
$script:testState.ConfirmPasswords['DOMAIN\svc-example'] = 'different-password'
$script:testState.CsvRows = @(
    [pscustomobject]@{
        Componente = 'FirstPool'
        CuentaActual = 'DOMAIN\svc-example'
    }
    [pscustomobject]@{
        Componente = 'SecondPool'
        CuentaActual = 'DOMAIN\svc-example'
    }
)

$mismatchResult = Restore-IisPoolsFromCsv -CsvPath 'pools.csv' -RestartPool 3>$null
Assert-Equal $script:testState.PromptedAccounts.Count 2 'A mismatched account should still receive exactly one confirmation attempt.'
Assert-Equal $mismatchResult.Skipped 2 'Every pool using a mismatched account should be skipped.'
Assert-Equal $mismatchResult.Updated 0 'A mismatched password should not update any pool.'
Assert-Equal $mismatchResult.Failed 0 'A password mismatch should be reported as skipped, not as a pool processing failure.'
Assert-Equal $script:testState.SavedSettings.Count 0 'A mismatched password should not save pool settings.'
Assert-Equal $script:testState.Pool.processModel.userName 'DOMAIN\svc-old' 'A mismatched password should preserve the current pool account.'
Assert-Equal $script:testState.Pool.processModel.password 'old-password' 'A mismatched password should preserve the current pool password.'
Assert-Equal $script:testState.RestartedPools.Count 0 'A mismatched password should not restart any pool.'
$testsPassed++

# Write-IisChangeLog_AppendsCsvEntries
$tempLogPath = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString() + '.csv')
try {
    $logEntry = [pscustomobject]@{
        Timestamp = '2026-01-01T00:00:00.0000000+00:00'
        Server = 'SVR01'
        PoolName = 'ExamplePool'
        Account = 'DOMAIN\svc-example'
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

# Restore-IisPoolsFromCsv_MissingCsv_ThrowsFileNotFoundError
Reset-TestState
$script:testState.CsvExists = $false
Assert-Throws {
    Restore-IisPoolsFromCsv -CsvPath 'missing.csv'
} 'Missing CSV should cause an error.'
$testsPassed++

# Set-IisAppPoolAccount_IisProviderUnavailable_ThrowsAvailabilityError
Reset-TestState
$script:testState.IisAvailable = $false
Assert-Throws {
    Set-IisAppPoolAccount -PoolNames 'ExamplePool' -UserName 'DOMAIN\svc-example' -Password 'secret'
} 'Unavailable IIS provider should cause an error.'
$testsPassed++

Write-Host "Passed $testsPassed PowerShell tests."
