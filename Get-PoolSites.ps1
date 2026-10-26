[CmdletBinding()]
param(
    [string[]]$TargetPools = @(
        "iispool1",
        "iispool2"
    )
)

Import-Module WebAdministration -ErrorAction Stop

if (-not (Get-PSDrive -Name IIS -ErrorAction SilentlyContinue)) {
    throw "IIS no está disponible en este servidor."
}

$targetPools = @(
    $TargetPools |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim() }
)

if ($targetPools.Count -eq 0) {
    throw "Debe especificar al menos un nombre de Application Pool."
}

# Ruta del CSV en el mismo directorio del script
$csvPath = Join-Path $PSScriptRoot "IIS_Site_Pool_Relation.csv"

# Recolectar relación Site - Application - Pool, incluyendo la aplicación raíz.
$result = foreach ($site in (Get-Website -ErrorAction Stop)) {
    if ($targetPools -contains $site.ApplicationPool) {
        [PSCustomObject]@{
            Site = $site.Name
            Application = "/"
            Pool = $site.ApplicationPool
        }
    }

    foreach ($application in (Get-WebApplication -Site $site.Name -ErrorAction Stop)) {
        if ($targetPools -contains $application.ApplicationPool) {
            [PSCustomObject]@{
                Site = $site.Name
                Application = $application.Path
                Pool = $application.ApplicationPool
            }
        }
    }
}

# Exportar a CSV
$sortedResult = @($result | Sort-Object Site, Application, Pool)
if ($sortedResult.Count -gt 0) {
    $sortedResult | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
}
else {
    '"Site","Application","Pool"' |
        Set-Content -Path $csvPath -Encoding UTF8 -ErrorAction Stop
}

Write-Host "CSV creado en: $csvPath"
