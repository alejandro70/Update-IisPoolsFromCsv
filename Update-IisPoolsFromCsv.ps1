[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)]
    [string]$CsvPath,

    [string]$LogPath = (Join-Path $PSScriptRoot 'Update-IisPoolsFromCsv.log')
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

# Actualiza la identidad de uno o más pools y devuelve el resultado por pool.
function Set-IisAppPoolGmsa {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)]
        [string[]]$PoolNames,

        [Parameter(Mandatory)]
        [string]$GmsaUser,

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
            $action = "Actualizar la identidad a '$GmsaUser'"
            if ($willRestart) {
                $action += ' y reiniciar el pool'
            }

            if ($PSCmdlet.ShouldProcess($poolName, $action)) {
                $pool.processModel.identityType = "SpecificUser"
                $pool.processModel.userName = $GmsaUser
                $pool.processModel.password = ""

                $pool | Set-Item -ErrorAction Stop

                $message = "Application Pool '$poolName' actualizado con la cuenta '$GmsaUser'."
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
                    Message = "Simulación: se actualizaría el Application Pool '$poolName' con la cuenta '$GmsaUser'$(if ($willRestart) { ' y se reiniciaría' })."
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

# Valida el CSV, filtra las filas del servidor actual y resume los resultados.
function Update-IisPoolsFromCsv {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)]
        [string]$CsvPath,

        [switch]$RestartPool
    )

    if (-not (Test-Path $CsvPath)) {
        throw "No se encontró el archivo CSV: $CsvPath"
    }

    $requiredColumns = @('Componente', 'CuentaGMSA')
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

        if ([string]::IsNullOrWhiteSpace($row.CuentaGMSA)) {
            Write-Warning "Se omite '$($row.Componente)' porque la columna CuentaGMSA está vacía."
            $skipped++
            continue
        }

        foreach ($result in (Set-IisAppPoolGmsa -PoolNames @($row.Componente) -GmsaUser $row.CuentaGMSA -RestartPool:$RestartPool -WhatIf:$WhatIfPreference)) {
            $changes += [pscustomobject]@{
                PoolName = $result.PoolName
                GmsaUser = $row.CuentaGMSA
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

$result = Update-IisPoolsFromCsv -CsvPath $CsvPath -RestartPool -WhatIf:$WhatIfPreference
foreach ($change in $result.Changes) {
    Write-IisChangeLog -Path $LogPath -Entry ([pscustomobject]@{
        Timestamp = [DateTimeOffset]::Now.ToString('o')
        Server = $env:COMPUTERNAME
        PoolName = $change.PoolName
        GmsaUser = $change.GmsaUser
        Status = $change.Status
        Message = $change.Message
    })
}

Write-Host "Resumen: $($result.TotalRows) filas; $($result.Updated) actualizadas; $($result.WhatIf) simuladas; $($result.Skipped) omitidas; $($result.Failed) fallidas."
Write-Host "Registro de cambios: $LogPath"

if ($result.Failed -gt 0) {
    throw "La ejecución terminó con $($result.Failed) error(es): $($result.Errors -join '; ')"
}
