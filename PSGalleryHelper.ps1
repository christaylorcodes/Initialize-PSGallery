function Initialize-PSGallery {
    <#
    .SYNOPSIS
    Preps machine for PowerShell Gallery usage.

    .DESCRIPTION
    Will address common issues that prevent Gallery usage.

    .NOTES
    Version:        1.0
    Author:         Chris Taylor
    Creation Date:  1/20/2020
    Purpose/Change: Initial script development
    #>
    [cmdletbinding()]
    param()
    $NuGetMinVersion = [System.Version]'2.8.5.201'
    $PackageManagementMinVersion = [System.Version]'1.4.4'
    $PowerShellGetMinVersion = [System.Version]'2.2.5'
    $GalleryURL = 'https://www.powershellgallery.com/api/v2/'
    # Fallback packages for when Install-Module can't be used. Gallery API package URLs redirect to
    # whatever CDN the gallery currently uses (the old psg-prod-eastus.azureedge.net host was retired).
    # Gallery package versions are immutable, so the SHA256 of each nupkg is pinned.
    $FallbackPackages = @{
        PowerShellGet     = @{
            URL    = 'https://www.powershellgallery.com/api/v2/package/PowerShellGet/2.2.5'
            SHA256 = '6B8CEBF2A464EAEB31B0A6D627355C30D9D1899DBA0CE3BDD0D4E7AFCA148673'
        }
        PackageManagement = @{
            URL    = 'https://www.powershellgallery.com/api/v2/package/PackageManagement/1.4.8.1'
            SHA256 = '7E1F8A75B6BC8A83D8ABFF79F6690FC1DFBD534FD3E5733D97E19BCB5954C13E'
        }
    }

    function Register-PSGallery {
        if ($Host.Version.Major -gt 4) { Register-PSRepository -Default }
        else {
            Import-Module PowerShellGet
            Register-PSRepository -Name PSGallery -SourceLocation $GalleryURL -InstallationPolicy Trusted
        }
    }

    function _Install-Module {
        [cmdletbinding()]
        param(
            [Parameter(mandatory = $true)]
            $Module,
            [Parameter(mandatory = $true)]
            $ModuleURL,
            [Parameter(mandatory = $true)]
            $SHA256
        )
        $DownloadPath = "$env:TEMP\$($Module).zip"
        $ExtractPath = "$env:TEMP\$($Module)"
        Remove-Item @($DownloadPath, $ExtractPath) -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
        # Download, verify, extract and validate before removing the installed copy, so a failed
        # download doesn't also delete what's in Program Files.
        try {
            Invoke-RestMethod $ModuleURL -OutFile $DownloadPath -UseBasicParsing -ErrorAction Stop
            # .NET hashing rather than Get-FileHash, which doesn't exist on PowerShell 3.
            $Stream = [System.IO.File]::OpenRead($DownloadPath)
            try { $Hash = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($Stream)) -replace '-' }
            finally { $Stream.Dispose() }
            if ($Hash -ne $SHA256) { throw "SHA256 mismatch: expected $SHA256, got $Hash." }
            Unblock-File $DownloadPath -ErrorAction Stop
            Add-Type -Assembly 'System.IO.Compression.Filesystem' -ErrorAction Stop
            [System.IO.Compression.ZipFile]::ExtractToDirectory($DownloadPath, $ExtractPath)
            if (-not (Test-Path "$ExtractPath\$($Module).psd1")) { throw "Manifest $($Module).psd1 not found in package." }
            if ($PSVersionTable.PSVersion.Major -ge 5) {
                $ModuleData = Import-PowerShellDataFile -Path "$ExtractPath\$($Module).psd1" -ErrorAction Stop
            }
        }
        catch {
            Remove-Item @($DownloadPath, $ExtractPath) -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
            # Wrap rather than replace, so the original exception stays available as InnerException.
            throw (New-Object System.Exception "Failed to download/extract $Module from $($ModuleURL): $($_.Exception.Message)", $_.Exception)
        }

        if ($PSVersionTable.PSVersion.Major -ge 5) {
            Remove-Item "$env:ProgramFiles\WindowsPowerShell\Modules\$Module" -Recurse -Force -ErrorAction SilentlyContinue
            $null = New-Item "$env:ProgramFiles\WindowsPowerShell\Modules\$Module\$($ModuleData.ModuleVersion)" -ItemType Directory -Force
            [System.IO.Compression.ZipFile]::ExtractToDirectory($DownloadPath, "$env:ProgramFiles\WindowsPowerShell\Modules\$Module\$($ModuleData.ModuleVersion)")
        }
        else {
            # These versions of PoSh want the files in the root of the drive not version sub folders
            Remove-Item "$env:ProgramFiles\WindowsPowerShell\Modules\$Module" -Recurse -Force -ErrorAction SilentlyContinue
            $null = New-Item "$env:ProgramFiles\WindowsPowerShell\Modules\$Module" -ItemType Directory -ErrorAction SilentlyContinue
            Copy-Item $ExtractPath "$env:ProgramFiles\WindowsPowerShell\Modules" -Force -Recurse
        }

        Remove-Item @($DownloadPath, $ExtractPath) -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
    }
    
    function Redo-Module {
        param(
            [Parameter(mandatory = $true)]
            [ValidateSet('PowerShellGet', 'PackageManagement')]
            $Module
        )
        Write-Verbose "Issue with $Module, Reinstalling."
        try {
            foreach ($ProfilePath in $env:PSModulePath.Split(';')) {
                $FullPath = Join-Path $ProfilePath $Module
                Get-ChildItem $FullPath -Exclude '1.0.0.1' -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
            }
            Register-PSGallery -ErrorAction Stop
            $null = Install-Module $Module -Force -AllowClobber -ErrorAction Stop
        }
        catch {
            _Install-Module -Module $Module -ModuleURL $FallbackPackages[$Module].URL -SHA256 $FallbackPackages[$Module].SHA256
        }
        Import-Module $Module -Force -ErrorAction Stop
    }

    if ($PSVersionTable.PSVersion.Major -lt 3) { Write-Error 'Requires PowerShell version 3 or greater.' -ErrorAction Stop }

    try {
        [version]$DotNetVersion = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Version).Version
        if ($DotNetVersion -lt '4.5') { throw }
    }
    catch { Write-Error '.NET version 4.5 or greater is needed.' -ErrorAction Stop }

    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }
    catch { Write-Error 'TLS 1.2 Not supported.' -ErrorAction Stop }

    # Everything from here to the gallery check is best-effort environment repair. Callers commonly
    # set $ErrorActionPreference = 'Stop' before dot-sourcing this helper, which promotes even
    # non-terminating errors, so each step is isolated - none of them should abort the bootstrap.
    try {
        $WinmgmtService = Get-Service Winmgmt -ErrorAction Stop
        if ($WinmgmtService.StartType -eq 'Disabled') { Set-Service winmgmt -StartupType Manual -ErrorAction Stop }
    }
    catch { Write-Verbose "Could not set Winmgmt startup type: $($_.Exception.Message)" }

    # Requires admin; throws SecurityException when running unelevated.
    try {
        if ($env:PSModulePath -split ';' -notcontains "$env:ProgramFiles\WindowsPowerShell\Modules") {
            [Environment]::SetEnvironmentVariable(
                'PSModulePath',
                ((([Environment]::GetEnvironmentVariable('PSModulePath', 'Machine') -split ';') + "$env:ProgramFiles\WindowsPowerShell\Modules") -join ';'),
                'Machine'
            )
        }
    }
    catch { Write-Verbose "Could not update machine PSModulePath: $($_.Exception.Message)" }
    
    # Remove Package Management Preview
    try { $null = & MsiExec /X '{57E5A8BB-41EB-4F09-B332-B535C5954A28}' /qn }
    catch { Write-Verbose "Could not remove PackageManagement preview MSI: $($_.Exception.Message)" }
    
    # A GPO-enforced execution policy makes this throw a terminating SecurityException
    # (ExecutionPolicyOverride) that -ErrorAction SilentlyContinue cannot suppress. When that happens
    # the effective policy is already set by policy and is usually permissive enough, so failing here
    # must not abort the bootstrap.
    try { Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope Process -Confirm:$false -Force -ErrorAction Stop }
    catch { Write-Verbose "Could not set process execution policy (likely GPO-enforced): $($_.Exception.Message)" }

    try { $null = Invoke-RestMethod $GalleryURL -UseBasicParsing }
    catch { throw "Unable to contact gallery: $GalleryURL" }

    # If PackageManagement is missing entirely, the NuGet step below can't run, so repair it first.
    # An outdated-but-present PackageManagement (e.g. in-box 1.0.0.1) is left to the normal flow,
    # where installing PowerShellGet pulls in a current PackageManagement as a dependency.
    if (-not (Get-Command Get-PackageProvider -ErrorAction SilentlyContinue) -or -not (Get-Command Install-PackageProvider -ErrorAction SilentlyContinue)) {
        Redo-Module PackageManagement
    }

    # Seems NuGet needs to be installed first
    try { $Nuget = Get-PackageProvider NuGet -ListAvailable -ErrorAction Stop | Where-Object { $_.Version -ge $NuGetMinVersion } }
    catch { $Nuget = $null }
    if (!$Nuget) {
        $null = Install-PackageProvider NuGet -MinimumVersion $NuGetMinVersion -Force -Confirm:$false
        try { Update-Module PowerShellGet -Confirm:$false -ErrorAction Stop }
        catch { 
            try { Install-Module PowerShellGet -Force -Confirm:$false -ErrorAction Stop }
            catch { Redo-Module PowerShellGet }
        }
    }

    try {
        $null = Get-Command Install-PackageProvider -ErrorAction Stop
        $null = Get-Command Get-PackageProvider -ErrorAction Stop
        $PackageManagement = Get-Module PackageManagement -ListAvailable -ErrorAction Stop | Sort-Object Version -Descending | Select-Object -First 1
        if (!$PackageManagement -or $PackageManagement.Version -lt $PackageManagementMinVersion) { throw }
    }
    catch { Redo-Module PackageManagement }

    try {
        $null = Get-Command Install-Module -ErrorAction Stop
        $PowerShellGet = Get-Module PowerShellGet -ListAvailable -ErrorAction Stop | Sort-Object Version -Descending | Select-Object -First 1
        if (!$PowerShellGet -or $PowershellGet.Version -lt $PowerShellGetMinVersion) { throw }
    }
    catch { Redo-Module PowerShellGet }

    try { $null = Get-PackageSource -Name PSNuGet -ErrorAction Stop }
    catch { $null = Register-PackageSource -Name PSNuGet -Location $GalleryURL -ProviderName NuGet -Force }

    try { $null = Get-PSRepository 'PSGallery' -ErrorAction Stop }
    catch {
        if ($_.exception.message -eq 'Invalid class' -or $_.exception.message -eq 'Unable to find module providers (PowerShellGet).') {
            Redo-Module PowerShellGet
        }
        else {
            Write-Verbose 'Registering PSGallery.'
            Remove-Item "$env:LOCALAPPDATA\Microsoft\windows\PowerShell\PowerShellGet\PSRepositories.xml" -ErrorAction SilentlyContinue
            Register-PSGallery
        }
    }

    if ((Get-PSRepository 'PSGallery').InstallationPolicy -ne 'Trusted') { Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted }
}
Initialize-PSGallery -ErrorAction Stop