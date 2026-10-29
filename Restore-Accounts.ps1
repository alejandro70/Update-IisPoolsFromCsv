[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)]
    [string]$CsvPath,

    [string]$LogPath = (Join-Path $PSScriptRoot 'Restore-Accounts.log')
)

Import-Module WebAdministration -ErrorAction Stop

# Lee el encabezado respetando campos CSV entrecomillados.
function Get-CsvHeaders {
    param(
        [Parameter(Mandatory)]
        [string]$CsvPath
    )

    # Windows PowerShell 5.1 no carga este ensamblado por defecto.
    Add-Type -AssemblyName Microsoft.VisualBasic

    $parser = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($CsvPath)
    try {
        $parser.TextFieldType = [Microsoft.VisualBasic.FileIO.FieldType]::Delimited
        $parser.SetDelimiters(',')
        $parser.HasFieldsEnclosedInQuotes = $true

        if ($parser.EndOfData) {
            throw "El archivo CSV está vacío: $CsvPath"
        }

        return @($parser.ReadFields())
    }
    finally {
        $parser.Dispose()
    }
}

# Escribe una entrada CSV en el registro de cambios.
function Write-IisChangeLog {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [psobject]$Entry
    )

    $csvLines = @($Entry | ConvertTo-Csv -NoTypeInformation)
    if ([System.IO.File]::Exists($Path)) {
        $csvLines = @($csvLines | Select-Object -Skip 1)
    }

    $content = ($csvLines -join [Environment]::NewLine) + [Environment]::NewLine
    [System.IO.File]::AppendAllText($Path, $content, [System.Text.UTF8Encoding]::new($true))
}

# Compara dos SecureString sin crear copias de texto plano para la comparación.
function Test-SecureStringEqual {
    param(
        [Parameter(Mandatory)]
        [System.Security.SecureString]$First,

        [Parameter(Mandatory)]
        [System.Security.SecureString]$Second
    )

    $firstBstr = [IntPtr]::Zero
    $secondBstr = [IntPtr]::Zero
    try {
        $firstBstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($First)
        $secondBstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Second)
        $firstByteLength = [Runtime.InteropServices.Marshal]::ReadInt32($firstBstr, -4)
        $secondByteLength = [Runtime.InteropServices.Marshal]::ReadInt32($secondBstr, -4)

        if ($firstByteLength -ne $secondByteLength) {
            return $false
        }

        for ($offset = 0; $offset -lt $firstByteLength; $offset += 2) {
            if ([Runtime.InteropServices.Marshal]::ReadInt16($firstBstr, $offset) -ne
                [Runtime.InteropServices.Marshal]::ReadInt16($secondBstr, $offset)) {
                return $false
            }
        }

        return $true
    }
    finally {
        if ($firstBstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($firstBstr)
        }
        if ($secondBstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secondBstr)
        }
    }
}

# Restaura la identidad de uno o más pools y devuelve el resultado por pool.
function Set-IisAppPoolAccount {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)]
        [string[]]$PoolNames,

        [Parameter(Mandatory)]
        [string]$UserName,

        [AllowEmptyString()]
        [string]$Password = '',

        [switch]$RestartPool
    )

    if (-not (Get-PSDrive -Name IIS -ErrorAction SilentlyContinue)) {
        throw "IIS no está disponible en este servidor."
    }

    foreach ($poolName in $PoolNames) {
        $poolPath = "IIS:\AppPools\$poolName"

        if (-not (Test-Path $poolPath)) {
            Write-Warning "No se encontró el Application Pool '$poolName'."
            [pscustomobject]@{
                PoolName = $poolName
                Status = 'Skipped'
                Message = "No se encontró el Application Pool '$poolName'."
            }
            continue
        }

        try {
            $pool = Get-Item $poolPath -ErrorAction Stop

            $willRestart = $RestartPool -and $pool.State -eq "Started"
            $action = "Restaurar la identidad a '$UserName'"
            if ($willRestart) {
                $action += ' y reiniciar el pool'
            }

            if ($PSCmdlet.ShouldProcess($poolName, $action)) {
                $pool.processModel.identityType = "SpecificUser"
                $pool.processModel.userName = $UserName
                $pool.processModel.password = $Password

                $pool | Set-Item -ErrorAction Stop

                $message = "Application Pool '$poolName' restaurado con la cuenta '$UserName'."
                if ($willRestart) {
                    try {
                        Restart-WebAppPool -Name $poolName -ErrorAction Stop
                    }
                    catch {
                        throw "La configuración se guardó, pero falló el reinicio: $($_.Exception.Message)"
                    }
                    $message += " Pool reiniciado."
                }

                [pscustomobject]@{
                    PoolName = $poolName
                    Status = 'Updated'
                    Message = $message
                }
            }
            else {
                [pscustomobject]@{
                    PoolName = $poolName
                    Status = 'WhatIf'
                    Message = "Simulación: se restauraría el Application Pool '$poolName' con la cuenta '$UserName'$(if ($willRestart) { ' y se reiniciaría' })."
                }
            }
        }
        catch {
            [pscustomobject]@{
                PoolName = $poolName
                Status = 'Failed'
                Message = "Error al procesar el Application Pool '$poolName': $($_.Exception.Message)"
            }
        }
    }
}

# Valida el CSV, solicita las contraseñas de forma interactiva, restaura las cuentas de los pools y resume los resultados.
function Restore-IisPoolsFromCsv {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)]
        [string]$CsvPath,

        [switch]$RestartPool
    )

    if (-not (Test-Path $CsvPath)) {
        throw "No se encontró el archivo CSV: $CsvPath"
    }

    $requiredColumns = @('Componente', 'CuentaActual')
    $headers = Get-CsvHeaders -CsvPath $CsvPath
    $missingColumns = @(
        foreach ($column in $requiredColumns) {
            if ($headers -notcontains $column) {
                $column
            }
        }
    )
    $duplicateColumns = @(
        foreach ($column in $requiredColumns) {
            if (@($headers | Where-Object { $_ -eq $column }).Count -gt 1) {
                $column
            }
        }
    )

    if ($missingColumns.Count -gt 0 -or $duplicateColumns.Count -gt 0) {
        $validationErrors = @()
        if ($missingColumns.Count -gt 0) {
            $validationErrors += "faltan: $($missingColumns -join ', ')"
        }
        if ($duplicateColumns.Count -gt 0) {
            $validationErrors += "están duplicadas: $($duplicateColumns -join ', ')"
        }

        throw "El encabezado del CSV no es válido ($($validationErrors -join '; '))."
    }

    $rows = @(Import-Csv -Path $CsvPath -ErrorAction Stop)

    # Solicita y confirma una sola vez la contraseña de cada cuenta tradicional distinta.
    # Las cuentas gMSA (terminadas en '$') no usan contraseña.
    $passwords = @{}
    $passwordFailures = @{}
    if (-not $WhatIfPreference) {
        $accounts = @(
            $rows |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_.CuentaActual) -and -not $_.CuentaActual.Trim().EndsWith('$') } |
                ForEach-Object { $_.CuentaActual.Trim() } |
                Sort-Object -Unique
        )

        foreach ($account in $accounts) {
            $securePassword = Read-Host "Contraseña de la cuenta '$account'" -AsSecureString
            $secureConfirmation = $null
            try {
                $secureConfirmation = Read-Host "Confirmar contraseña de la cuenta '$account'" -AsSecureString
                if (-not (Test-SecureStringEqual -First $securePassword -Second $secureConfirmation)) {
                    $passwordFailures[$account] = $true
                    continue
                }

                $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
                try {
                    $passwords[$account] = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
                }
                finally {
                    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
                }
            }
            finally {
                if ($null -ne $securePassword) {
                    $securePassword.Dispose()
                }
                if ($null -ne $secureConfirmation) {
                    $secureConfirmation.Dispose()
                }
            }
        }
    }

    $updated = 0
    $skipped = 0
    $whatIf = 0
    $failed = 0
    $errors = @()
    $changes = @()

    foreach ($row in $rows) {
        if ([string]::IsNullOrWhiteSpace($row.Componente)) {
            Write-Warning "Se omite una fila porque la columna Componente está vacía."
            $skipped++
            continue
        }

        if ([string]::IsNullOrWhiteSpace($row.CuentaActual)) {
            Write-Warning "Se omite '$($row.Componente)' porque la columna CuentaActual está vacía."
            $skipped++
            continue
        }

        $account = $row.CuentaActual.Trim()
        $isGmsa = $account.EndsWith('$')
        $password = ''
        if (-not $isGmsa -and -not $WhatIfPreference) {
            if ($passwordFailures.ContainsKey($account)) {
                Write-Warning "Se omite '$($row.Componente)' porque las contraseñas ingresadas para la cuenta '$account' no coinciden."
                $skipped++
                continue
            }
            if ([string]::IsNullOrEmpty($passwords[$account])) {
                Write-Warning "Se omite '$($row.Componente)' porque no se proporcionó contraseña para la cuenta '$account'."
                $skipped++
                continue
            }
            $password = $passwords[$account]
        }

        foreach ($result in (Set-IisAppPoolAccount -PoolNames @($row.Componente) -UserName $account -Password $password -RestartPool:$RestartPool -WhatIf:$WhatIfPreference)) {
            $changes += [pscustomobject]@{
                PoolName = $result.PoolName
                Account = $account
                Status = $result.Status
                Message = $result.Message
            }

            if ($result.Status -eq 'Updated') {
                $updated++
                Write-Host $result.Message
            }
            elseif ($result.Status -eq 'WhatIf') {
                $whatIf++
                Write-Host $result.Message
            }
            elseif ($result.Status -eq 'Failed') {
                $failed++
                $errors += $result.Message
                Write-Error $result.Message -ErrorAction Continue
            }
            else {
                $skipped++
            }
        }
    }

    [pscustomobject]@{
        CsvPath = $CsvPath
        TotalRows = $rows.Count
        Updated = $updated
        WhatIf = $whatIf
        Skipped = $skipped
        Failed = $failed
        Errors = @($errors)
        Changes = @($changes)
    }
}

$resolvedCsvPath = [System.IO.Path]::Combine($PSScriptRoot, $CsvPath)
$result = Restore-IisPoolsFromCsv -CsvPath $resolvedCsvPath -RestartPool -WhatIf:$WhatIfPreference
foreach ($change in $result.Changes) {
    Write-IisChangeLog -Path $LogPath -Entry ([pscustomobject]@{
        Timestamp = [DateTimeOffset]::Now.ToString('o')
        Server = $env:COMPUTERNAME
        PoolName = $change.PoolName
        Account = $change.Account
        Status = $change.Status
        Message = $change.Message
    })
}

Write-Host "Resumen: $($result.TotalRows) filas; $($result.Updated) restauradas; $($result.WhatIf) simuladas; $($result.Skipped) omitidas; $($result.Failed) fallidas."
Write-Host "Registro de cambios: $LogPath"

if ($result.Failed -gt 0) {
    throw "La ejecución terminó con $($result.Failed) error(es): $($result.Errors -join '; ')"
}
