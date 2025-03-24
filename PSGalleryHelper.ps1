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
    Param()
    $NuGetMinVersion = [System.Version]'2.8.5.201'
    $PackageManagementMinVersion = [System.Version]'1.4.4'
    $GalleryURL = 'https://www.powershellgallery.com/api/v2/'
    $PowerShellGetURL = 'https://psg-prod-eastus.azureedge.net/packages/powershellget.2.2.5.nupkg'
    $PackageManagementURL = 'https://psg-prod-eastus.azureedge.net/packages/packagemanagement.1.4.7.nupkg'

    function Register-PSGallery {
        if ($Host.Version.Major -gt 4) { Register-PSRepository -Default }
        else {
            Import-Module PowerShellGet
            Register-PSRepository -Name PSGallery -SourceLocation $GalleryURL -InstallationPolicy Trusted
        }
    }

    function _Install-Module {
        [cmdletbinding()]
        Param(
            [Parameter(mandatory = $true)]
            $Module,
            [Parameter(mandatory = $true)]
            $ModuleURL
        )
        $DownloadPath = "$env:TEMP\$($Module).zip"
        $ExtractPath = "$env:TEMP\$($Module)"
        Remove-Item @($DownloadPath, $ExtractPath) -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
        Invoke-RestMethod $ModuleURL -OutFile $DownloadPath
        Unblock-File $DownloadPath
        Add-Type -Assembly 'System.IO.Compression.Filesystem'
        [System.IO.Compression.ZipFile]::ExtractToDirectory($DownloadPath, $ExtractPath)
        
        if ($PSVersionTable.PSVersion.Major -ge 5) {
            $ModuleData = Import-PowerShellDataFile -Path "$ExtractPath\$($Module).psd1"
            Remove-Item "$env:ProgramFiles\WindowsPowerShell\Modules\$Module" -Recurse -Force -ErrorAction SilentlyContinue
            $null = New-Item "$env:ProgramFiles\WindowsPowerShell\Modules\$Module\$($ModuleData.ModuleVersion)" -ItemType Directory -Force
            [System.IO.Compression.ZipFile]::ExtractToDirectory($DownloadPath, "$env:ProgramFiles\WindowsPowerShell\Modules\$Module\$($ModuleData.ModuleVersion)")
        }
        else {
            # These versions of PoSh want the files in the root of the drive not version sub folders
            Remove-Item "$env:ProgramFiles\WindowsPowerShell\Modules\$Module" -Recurse -Force -ErrorAction SilentlyContinue
            $null = New-Item "$env:ProgramFiles\WindowsPowerShell\Modules\$Module" -ItemType Directory -ErrorAction SilentlyContinue
            Copy-Item "$env:TEMP\$Module" "$env:ProgramFiles\WindowsPowerShell\Modules" -Force -Recurse
        }

        Remove-Item @($DownloadPath, $ExtractPath) -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
    }
    
    function Redo-PowerShellGet {
        Write-Verbose 'Issue with PowerShellGet, Reinstalling.'
        $Module = 'PowerShellGet'
        try {
            foreach ($ProfilePath in $env:PSModulePath.Split(';')) {
                $FullPath = Join-Path $ProfilePath $Module
                Get-ChildItem $FullPath -Exclude '1.0.0.1' -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
            }
            Register-PSGallery -ErrorAction Stop
            $null = Install-Module $Module -Force -AllowClobber -ErrorAction Stop
        }
        catch {
            _Install-Module -Module $Module -ModuleURL $PowerShellGetURL
        }
        Import-Module $Module -Force
    }

    function Redo-PackageManagement {
        Write-Verbose 'Issue with PackageManagement, Reinstalling.'
        $Module = 'PackageManagement'
        try {
            foreach ($ProfilePath in $env:PSModulePath.Split(';')) {
                $FullPath = Join-Path $ProfilePath $Module
                Get-ChildItem $FullPath -Exclude '1.0.0.1' -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
            }
            Register-PSGallery -ErrorAction Stop
            $null = Install-Module $Module -Force -AllowClobber -ErrorAction Stop
        }
        catch {
            _Install-Module -Module $Module -ModuleURL $PackageManagementURL
        }
        Import-Module $Module -Force
    }

    if ($PSVersionTable.PSVersion.Major -lt 3) { Write-Error 'Requires PowerShell version 3 or greater.' -ErrorAction Stop }

    try {
        [version]$DotNetVersion = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Version).Version
        if ($DotNetVersion -lt '4.5') { throw }
    }
    catch { Write-Error '.NET version 4.5 or greater is needed.' -ErrorAction Stop }

    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }
    catch { Write-Error 'TLS 1.2 Not supported.' -ErrorAction Stop }

    $WinmgmtService = Get-Service Winmgmt
    if ($WinmgmtService.StartType -eq 'Disabled') { Set-Service winmgmt -StartupType Manual }

    if ($env:PSModulePath -split ';' -notcontains "$env:ProgramFiles\WindowsPowerShell\Modules") {
        [Environment]::SetEnvironmentVariable(
            'PSModulePath',
            ((([Environment]::GetEnvironmentVariable('PSModulePath', 'Machine') -split ';') + "$env:ProgramFiles\WindowsPowerShell\Modules") -join ';'),
            'Machine'
        )
    }
    
    # Remove Package Management Preview
    $null = & MsiExec /X '{57E5A8BB-41EB-4F09-B332-B535C5954A28}' /qn
    
    Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope Process -Confirm:$false -Force -ErrorAction SilentlyContinue

    try { $null = Invoke-RestMethod $GalleryURL }
    catch { throw "Unable to contact gallery: $GalleryURL" }

    # Seems NuGet needs to be installed first
    $Nuget = Get-PackageProvider NuGet -ListAvailable -ErrorAction SilentlyContinue | Where-Object { $_.Version -gt $NuGetMinVersion }
    if (!$Nuget) {
        $null = Install-PackageProvider NuGet -MinimumVersion $NuGetMinVersion -Force -Confirm:$false
        try { Update-Module PowerShellGet -Confirm:$false -ErrorAction Stop }
        catch { 
            try { Install-Module PowerShellGet -Force -Confirm:$false -ErrorAction Stop }
            catch { Redo-PowerShellGet }
        }
    }

    try {
        $null = Get-Command Install-PackageProvider -ErrorAction Stop
        $null = Get-Command Get-PackageProvider -ErrorAction Stop
        $PackageManagement = Get-Module PackageManagement -ListAvailable -ErrorAction Stop | Sort-Object Version -Descending | Select-Object -First 1
        if ($PackageManagement.Version -lt $PackageManagementMinVersion) { throw }
    }
    catch { Redo-PackageManagement }

    try { $null = Get-Command Install-Module -ErrorAction Stop }
    catch { Redo-PowerShellGet }

    try { $null = Get-PackageSource -Name PSNuGet -ErrorAction Stop }
    catch { $null = Register-PackageSource -Name PSNuGet -Location $GalleryURL -ProviderName NuGet -Force }

    try { $null = Get-PSRepository 'PSGallery' -ErrorAction Stop }
    catch {
        if ($_.exception.message -eq 'Invalid class' -or $_.exception.message -eq 'Unable to find module providers (PowerShellGet).') {
            Redo-PowerShellGet
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