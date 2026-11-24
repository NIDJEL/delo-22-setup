[CmdletBinding()]
param([string]$OutputPath)

$ErrorActionPreference = 'Stop'
if (!$OutputPath) { $OutputPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Delo-Setup.exe' }
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (!(Test-Path -LiteralPath $compiler -PathType Leaf)) {
    throw 'Не найден компилятор C# из .NET Framework 4.x.'
}
$output = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
$resources = 'Install-Delo.ps1', 'VendorWizard.ps1', 'VendorFiles.json'
$arguments = @('/nologo', '/utf8output', '/codepage:65001', '/target:exe', '/platform:x64',
    '/optimize+', '/warnaserror+', "/out:$output", "/win32manifest:$PSScriptRoot\DeloSetup.manifest")
foreach ($resource in $resources) {
    $path = Join-Path $PSScriptRoot $resource
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw "Не найден файл $path." }
    $arguments += "/resource:$path,$resource"
}
& $compiler @arguments (Join-Path $PSScriptRoot 'DeloSetup.cs')
if ($LASTEXITCODE -ne 0) { throw "Ошибка сборки установщика, код $LASTEXITCODE." }
Get-Item -LiteralPath $output
