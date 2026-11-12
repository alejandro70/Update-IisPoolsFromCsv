# Autor:   Jairo Espitia
# Fecha:   2026-10-27
# Versión: 1.0

<#
.SYNOPSIS
Actualiza las identidades de los Application Pools de IIS a cuentas gMSA.

.DESCRIPTION
Lee el inventario CSV y busca cada combinación de Servidor, IP y Componente
en el catálogo de cuentas. Ambos archivos requieren esas tres columnas; el
catálogo requiere además CuentaGMSA. La columna CuentaGMSA del inventario,
si existe, se ignora. Solo se procesan filas de ambos archivos cuyo Servidor
coincide con el nombre local y cuya IP está asignada a una interfaz del equipo,
incluidas interfaces inactivas y de loopback. Los nombres de servidor se
comparan sin distinguir mayúsculas. La IP se interpreta como dirección IPv4 o
IPv6 para verificarla localmente; el cruce entre archivos sigue comparando IP y
Componente como texto exacto, sin recortar espacios y distinguiendo mayúsculas.
Se usa la primera fila del catálogo para cada combinación. Las filas inválidas,
sin cuenta o duplicadas se omiten y se registran. Una cuenta debe terminar en
'$'; no se comprueba su disponibilidad ni autorización en el servidor.
Cada pool se procesa una vez, sin distinguir mayúsculas al detectar duplicados
del inventario, ya que IIS no distingue mayúsculas en los nombres de pools.
El resumen cuenta filas del inventario; el registro también incluye las filas
inválidas o duplicadas del catálogo.

El script establece la identidad como SpecificUser y deja la contraseña vacía,
como corresponde a una cuenta gMSA. Los pools iniciados se reinician después
de guardar los cambios. La opción -WhatIf permite simular la ejecución sin
modificar ni reiniciar pools.

Los resultados se muestran en pantalla y se agregan al registro CSV indicado
por LogPath. La ruta del catálogo se muestra antes del procesamiento y se
incluye en el mensaje de cada entrada del registro.

.PARAMETER AuditoriaPath
Ruta del CSV de inventario del servidor local. Las rutas relativas se
resuelven desde la carpeta donde está este script. CsvPath se conserva como
alias para compatibilidad con ejecuciones existentes.

.PARAMETER CatalogoGmsaPath
Ruta del catálogo de cuentas gMSA. Por defecto, se usa
cuentas_gmsa_aprobadas.csv junto al script. Las rutas relativas se resuelven
desde la carpeta donde está este script. AccountsPath se conserva como alias
para compatibilidad con ejecuciones existentes.

.PARAMETER LogPath
Ruta del registro CSV de cambios. Por defecto, se usa Update-Accounts.log
junto a este script.

.EXAMPLE
.\Update-Accounts.ps1 -AuditoriaPath 'auditoria_servicios.csv'

Actualiza los pools indicados en el CSV y reinicia los que estaban iniciados.

.EXAMPLE
.\Update-Accounts.ps1 -AuditoriaPath 'auditoria_servicios.csv' -WhatIf

Muestra las acciones que se realizarían sin guardar cambios ni reiniciar pools.

.EXAMPLE
.\Update-Accounts.ps1 -AuditoriaPath 'auditoria_servicios.csv' -CatalogoGmsaPath 'catalogo.csv' -WhatIf

Simula la actualización usando un catálogo de cuentas alternativo.

.NOTES
Requiere Windows PowerShell con el módulo WebAdministration y permisos para
administrar Application Pools de IIS.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)]
    [Alias('CsvPath')]
    [string]$AuditoriaPath,

    [string]$LogPath = (Join-Path $PSScriptRoot 'Update-Accounts.log'),

    [ValidateNotNullOrEmpty()]
    [Alias('AccountsPath')]
    [string]$CatalogoGmsaPath = 'cuentas_gmsa_aprobadas.csv'
)

Import-Module WebAdministration -ErrorAction Stop

function Get-LocalIpAddresses {
    foreach ($interface in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        foreach ($address in $interface.GetIPProperties().UnicastAddresses) {
            $address.Address
        }
    }
}

function Test-LocalIpAddress {
    param(
        [string]$Address,
        [System.Net.IPAddress[]]$LocalAddresses
    )

    $parsedAddress = $null
    return $Address -ceq $Address.Trim() -and
        [System.Net.IPAddress]::TryParse($Address, [ref]$parsedAddress) -and
        $LocalAddresses.Contains($parsedAddress)
}

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

# Valida los CSV, relaciona sus componentes y resume los resultados.
function Update-IisPoolsFromCsv {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)]
        [string]$CsvPath,

        [Parameter(Mandatory)]
        [string]$AccountsPath,

        [switch]$RestartPool
    )

    foreach ($inputCsv in @(
        @{ Path = $CsvPath; Columns = @('Servidor', 'IP', 'Componente') }
        @{ Path = $AccountsPath; Columns = @('Servidor', 'IP', 'Componente', 'CuentaGMSA') }
    )) {
        if (-not (Test-Path $inputCsv.Path)) {
            throw "No se encontró el archivo CSV: $($inputCsv.Path)"
        }

        $headers = Get-CsvHeaders -CsvPath $inputCsv.Path
        $missingColumns = @(
            foreach ($column in $inputCsv.Columns) {
                if ($headers -notcontains $column) {
                    $column
                }
            }
        )
        $duplicateColumns = @(
            foreach ($column in $inputCsv.Columns) {
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

            throw "El encabezado del CSV '$($inputCsv.Path)' no es válido ($($validationErrors -join '; '))."
        }
    }

    $rows = @(Import-Csv -Path $CsvPath -ErrorAction Stop)
    $accountRows = @(Import-Csv -Path $AccountsPath -ErrorAction Stop)
    $updated = 0
    $skipped = 0
    $whatIf = 0
    $failed = 0
    $errors = @()
    $changes = @()

    $accounts = [System.Collections.Generic.Dictionary[System.Tuple[string,string,string],string]]::new()
    $localServer = [System.Environment]::MachineName
    $localAddresses = @(Get-LocalIpAddresses)
    if ($localAddresses.Count -eq 0) {
        throw "No se pudieron obtener direcciones IP asignadas al equipo local."
    }
    foreach ($accountRow in $accountRows) {
        if ([string]::IsNullOrWhiteSpace($accountRow.Servidor) -or [string]::IsNullOrWhiteSpace($accountRow.IP) -or [string]::IsNullOrWhiteSpace($accountRow.Componente)) {
            $message = "Se omite una fila del catálogo porque Servidor, IP o Componente está vacío."
        }
        elseif (-not [string]::Equals($accountRow.Servidor, $localServer, [System.StringComparison]::OrdinalIgnoreCase)) {
            $message = "Se omite '$($accountRow.Componente)' del catálogo porque el servidor '$($accountRow.Servidor)' no coincide con el servidor local '$localServer'."
        }
        elseif (-not (Test-LocalIpAddress -Address $accountRow.IP -LocalAddresses $localAddresses)) {
            $message = "Se omite '$($accountRow.Componente)' del catálogo porque la IP '$($accountRow.IP)' no es válida o no está asignada al equipo local."
        }
        else {
            $key = [System.Tuple]::Create($accountRow.Servidor.ToUpperInvariant(), [string]$accountRow.IP, [string]$accountRow.Componente)
            if ($accounts.ContainsKey($key)) {
                $message = "Se omite la fila duplicada del catálogo para '$($accountRow.Servidor)', '$($accountRow.IP)', '$($accountRow.Componente)'; se conserva la primera."
            }
            else {
                $accounts.Add($key, [string]$accountRow.CuentaGMSA)
                if ([string]::IsNullOrWhiteSpace($accountRow.CuentaGMSA)) {
                    $message = "La cuenta del catálogo para '$($accountRow.Servidor)', '$($accountRow.IP)', '$($accountRow.Componente)' está vacía."
                }
                elseif (-not $accountRow.CuentaGMSA.EndsWith('$')) {
                    $message = "La cuenta del catálogo para '$($accountRow.Servidor)', '$($accountRow.IP)', '$($accountRow.Componente)' no tiene formato gMSA."
                }
                else {
                    continue
                }
            }
        }

        Write-Warning $message
        $changes += [pscustomobject]@{
            PoolName = $accountRow.Componente
            GmsaUser = $accountRow.CuentaGMSA
            Status = 'Skipped'
            Message = $message
        }
    }

    $processedPools = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($row in $rows) {
        $gmsaUser = ''
        $message = $null
        if ([string]::IsNullOrWhiteSpace($row.Componente)) {
            $message = "Se omite una fila porque la columna Componente está vacía."
        }
        elseif ([string]::IsNullOrWhiteSpace($row.Servidor) -or [string]::IsNullOrWhiteSpace($row.IP)) {
            $message = "Se omite '$($row.Componente)' porque Servidor o IP está vacío."
        }
        elseif (-not [string]::Equals($row.Servidor, $localServer, [System.StringComparison]::OrdinalIgnoreCase)) {
            $message = "Se omite '$($row.Componente)' porque el servidor '$($row.Servidor)' no coincide con el servidor local '$localServer'."
        }
        elseif (-not (Test-LocalIpAddress -Address $row.IP -LocalAddresses $localAddresses)) {
            $message = "Se omite '$($row.Componente)' porque la IP '$($row.IP)' no es válida o no está asignada al equipo local."
        }
        else {
            $key = [System.Tuple]::Create($row.Servidor.ToUpperInvariant(), [string]$row.IP, [string]$row.Componente)
            if (-not $accounts.ContainsKey($key)) {
                $message = "Se omite '$($row.Componente)' porque no hay coincidencia de Servidor '$($row.Servidor)', IP '$($row.IP)' y Componente en el catálogo."
            }
            else {
                $gmsaUser = $accounts[$key]
                if ([string]::IsNullOrWhiteSpace($gmsaUser)) {
                    $message = "Se omite '$($row.Componente)' porque la cuenta del catálogo está vacía."
                }
                elseif (-not $gmsaUser.EndsWith('$')) {
                    $message = "Se omite '$($row.Componente)' porque la cuenta del catálogo no tiene formato gMSA."
                }
                elseif (-not $processedPools.Add($row.Componente)) {
                    $message = "Se omite '$($row.Componente)' porque el pool ya fue procesado en el inventario."
                }
            }
        }

        if ($null -ne $message) {
            Write-Warning $message
            $changes += [pscustomobject]@{
                PoolName = $row.Componente
                GmsaUser = $gmsaUser
                Status = 'Skipped'
                Message = $message
            }
            $skipped++
            continue
        }

        foreach ($result in (Set-IisAppPoolGmsa -PoolNames @($row.Componente) -GmsaUser $gmsaUser -RestartPool:$RestartPool -WhatIf:$WhatIfPreference)) {
            $changes += [pscustomobject]@{
                PoolName = $result.PoolName
                GmsaUser = $gmsaUser
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

$resolvedCsvPath = [System.IO.Path]::Combine($PSScriptRoot, $AuditoriaPath)
$resolvedAccountsPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, $CatalogoGmsaPath))
Write-Host "Catálogo de cuentas: $resolvedAccountsPath"
$result = Update-IisPoolsFromCsv -CsvPath $resolvedCsvPath -AccountsPath $resolvedAccountsPath -RestartPool -WhatIf:$WhatIfPreference
foreach ($change in $result.Changes) {
    Write-IisChangeLog -Path $LogPath -Entry ([pscustomobject]@{
        Timestamp = [DateTimeOffset]::Now.ToString('o')
        Server = $env:COMPUTERNAME
        PoolName = $change.PoolName
        GmsaUser = $change.GmsaUser
        Status = $change.Status
        Message = "$($change.Message) Catálogo: $resolvedAccountsPath"
    })
}

Write-Host "Resumen: $($result.TotalRows) filas; $($result.Updated) actualizadas; $($result.WhatIf) simuladas; $($result.Skipped) omitidas; $($result.Failed) fallidas."
Write-Host "Registro de cambios: $LogPath"

if ($result.Failed -gt 0) {
    throw "La ejecución terminó con $($result.Failed) error(es): $($result.Errors -join '; ')"
}
