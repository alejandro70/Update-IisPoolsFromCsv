$s = "LAUSD-WWEBCHB01"
$ip = "172.25.109.151"
$csvMigrateFile = "migracion_LAUSD-WWEBCHB01.csv"

Import-Module WebAdministration -ErrorAction Stop

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
            continue
        }

        try {
            $pool = Get-Item $poolPath

            $pool.processModel.identityType = "SpecificUser"
            $pool.processModel.userName = $GmsaUser
            $pool.processModel.password = ""

            $pool | Set-Item

            Write-Host "Application Pool '$poolName' actualizado con la cuenta
GmsaUser'."

            if ($RestartPool) {
                if ($pool.State -eq "Started") {
                    Restart-WebAppPool -Name $poolName
                    Write-Host "Application Pool '$poolName' reiniciado."
                }
            }
        }
        catch {
            Write-Error "Error al actualizar '$poolName': $($_.Exception.Message)"
        }
    }
}

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

    $rows = Import-Csv -Path $CsvPath

    foreach ($row in $rows) {
        if ($row.Servidor -ne $CurrentServerName) {
            Write-Warning "Se omite '$($row.Componente)' porque el servidor '$($row.Servidor)' no coincide con el servidor actual '$CurrentServerName'."
            continue
        }

        if ($row.IP -ne $CurrentServerIp) {
            Write-Warning "Se omite '$($row.Componente)' porque la IP '$($row.IP)' no
incide con la IP actual '$CurrentServerIp'."
            continue
        }

        if ($row.Clasificacion -ne "IIS Pool") {
            Write-Warning "Se omite '$($row.Componente)' porque la clasificación no es
IS Pool'."
            continue
        }

        if ([string]::IsNullOrWhiteSpace($row.gMSA)) {
            Write-Warning "Se omite '$($row.Componente)' porque la columna gMSA está
cía."
            continue
        }

        Set-IisAppPoolGmsa -PoolNames @($row.Componente) -GmsaUser $row.gMSA -RestartPool
    }
}

$csvPath = Join-Path $PSScriptRoot $csvMigrateFile

Update-IisPoolsFromCsv -CsvPath $csvPath -CurrentServerIp $ip -CurrentServerName $s -RestartPool