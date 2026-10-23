$s = "ServerName"
$ip = "127.0.0.1"
$csvMigrateFile = "migracion_ServerName.csv"

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

# Actualiza la identidad de uno o más pools y devuelve el resultado por pool.
function Set-IisAppPoolGmsa {
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

            $pool.processModel.identityType = "SpecificUser"
            $pool.processModel.userName = $GmsaUser
            $pool.processModel.password = ""

            $pool | Set-Item -ErrorAction Stop

            $message = "Application Pool '$poolName' actualizado con la cuenta '$GmsaUser'."
            if ($RestartPool -and $pool.State -eq "Started") {
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
    param(
        [Parameter(Mandatory)]
        [string]$CsvPath,

        [Parameter(Mandatory)]
        [string]$CurrentServerIp,

        [Parameter(Mandatory)]
        [string]$CurrentServerName,

        [switch]$RestartPool
    )

    if (-not (Test-Path $CsvPath)) {
        throw "No se encontró el archivo CSV: $CsvPath"
    }

    $requiredColumns = @('Servidor', 'IP', 'Componente', 'Clasificacion', 'gMSA')
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
    $failed = 0
    $errors = @()

    foreach ($row in $rows) {
        if ($row.Servidor -ne $CurrentServerName) {
            Write-Warning "Se omite '$($row.Componente)' porque el servidor '$($row.Servidor)' no coincide con el servidor actual '$CurrentServerName'."
            $skipped++
            continue
        }

        if ($row.IP -ne $CurrentServerIp) {
            Write-Warning "Se omite '$($row.Componente)' porque la IP '$($row.IP)' no coincide con la IP actual '$CurrentServerIp'."
            $skipped++
            continue
        }

        if ($row.Clasificacion -ne "IIS Pool") {
            Write-Warning "Se omite '$($row.Componente)' porque la clasificación '$($row.Clasificacion)' no es 'IIS Pool'."
            $skipped++
            continue
        }

        if ([string]::IsNullOrWhiteSpace($row.Componente)) {
            Write-Warning "Se omite una fila porque la columna Componente está vacía."
            $skipped++
            continue
        }

        if ([string]::IsNullOrWhiteSpace($row.gMSA)) {
            Write-Warning "Se omite '$($row.Componente)' porque la columna gMSA está vacía."
            $skipped++
            continue
        }

        foreach ($result in (Set-IisAppPoolGmsa -PoolNames @($row.Componente) -GmsaUser $row.gMSA -RestartPool:$RestartPool)) {
            if ($result.Status -eq 'Updated') {
                $updated++
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
        Skipped = $skipped
        Failed = $failed
        Errors = @($errors)
    }
}

$csvPath = Join-Path $PSScriptRoot $csvMigrateFile
$result = Update-IisPoolsFromCsv -CsvPath $csvPath -CurrentServerIp $ip -CurrentServerName $s -RestartPool
Write-Host "Resumen: $($result.TotalRows) filas; $($result.Updated) actualizadas; $($result.Skipped) omitidas; $($result.Failed) fallidas."

if ($result.Failed -gt 0) {
    throw "La ejecución terminó con $($result.Failed) error(es): $($result.Errors -join '; ')"
}
