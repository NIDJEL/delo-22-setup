param(
    [Parameter(Mandatory)][string]$Package,
    [Parameter(Mandatory)][string]$CredentialPath,
    [Parameter(Mandatory)][string]$Server,
    [Parameter(Mandatory)][string]$Owner,
    [Parameter(Mandatory)][string]$SiteUrl
)

$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class DeloWebMsi {
    [DllImport("msi.dll", ExactSpelling = true)]
    private static extern uint MsiSetInternalUI(uint level, IntPtr owner);

    [DllImport("msi.dll", ExactSpelling = true, CharSet = CharSet.Unicode)]
    private static extern uint MsiEnableLogW(uint mode, string path, uint attributes);

    [DllImport("msi.dll", ExactSpelling = true, CharSet = CharSet.Unicode)]
    private static extern uint MsiInstallProductW(string path, string properties);

    public static uint Run(string path, string properties) {
        MsiSetInternalUI(5, IntPtr.Zero); // INSTALLUILEVEL_FULL
        MsiEnableLogW(0, null, 0);
        return MsiInstallProductW(path, properties);
    }
}
'@

$credential = [PSCredential]::new($Owner, (Import-Clixml -LiteralPath $CredentialPath))
$password = $credential.GetNetworkCredential().Password
if ($password -notmatch '\A[A-Za-z0-9!_-]+\z') { exit 87 }
$properties = @(
    'ISSETUPDRIVEN=1', 'DBTYPE=MSS', "DBSERVERNAME=$Server", "DBOWNER=$Owner", "DBPASSWORD=$password",
    "DELOWEBAPPNAME=$Owner", 'DELOWEBURLCHANGE=1', "DELOWEBURLCHANGED=$SiteUrl", 'REBOOT=ReallySuppress'
) -join ' '
# Provide the password directly to MSI without putting it in the process arguments.
exit [DeloWebMsi]::Run($Package, $properties)
