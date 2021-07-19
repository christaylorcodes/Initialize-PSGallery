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
    $ModuleDownloadURL = 'https://raw.githubusercontent.com/christaylorcodes/Initialize-PSGallery/main/PowerShellGetModules.zip'

    function Register-PSGallery {
        if($Host.Version.Major -gt 4){ Register-PSRepository -Default }
        else{
            Import-Module PowerShellGet
            Register-PSRepository -Name PSGallery -SourceLocation https://www.powershellgallery.com/api/v2/ -InstallationPolicy Trusted
        }
    }

    function Redo-PowerShellGet {
        Write-Verbose "Issue with PowerShellGet, Reinstalling."
        $Module = 'PowerShellGet'
        foreach($ProfilePath in $env:PSModulePath.Split(';')){
            $FullPath = Join-Path $ProfilePath $Module
            Get-ChildItem $FullPath -Exclude '1.0.0.1' -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
        }
        Register-PSGallery
        $null = Install-Module $Module -Force -AllowClobber
        Import-Module $Module -Force
    }

    if($PSVersionTable.PSVersion.Major -lt 3){ Write-Error 'Requires PowerShell version 3 or greater.' -ErrorAction Stop }

    try{
        [version]$DotNetVersion = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Version).Version
        if($DotNetVersion -lt '4.5'){ throw }
    }
    catch{ Write-Error '.NET version 4.5 or greater is needed.' -ErrorAction Stop }

    try{ [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }
    catch{ Write-Error 'TLS 1.2 Not supported.' -ErrorAction Stop }

    $WinmgmtService = Get-Service Winmgmt
    if($WinmgmtService.StartType -eq 'Disabled'){ Set-Service winmgmt -StartupType Manual }

    if($env:PSModulePath -split ';' -notcontains "$env:ProgramFiles\WindowsPowerShell\Modules"){
        [Environment]::SetEnvironmentVariable(
            'PSModulePath',
            ((([Environment]::GetEnvironmentVariable('PSModulePath', 'Machine') -split ';') + "$env:ProgramFiles\WindowsPowerShell\Modules") -join ';'),
            'Machine'
        )
    }

    Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope Process -Confirm:$false -Force

    try{
        $null = Get-Command Install-PackageProvider -ErrorAction Stop
        $null = Get-Command Install-Module -ErrorAction Stop
        $PackageManagement = Get-Module PackageManagement -ListAvailable -ErrorAction Stop | Sort-Object Version -Descending | Select-Object -First 1
        if($PackageManagement.Version -lt $PackageManagementMinVersion){ throw }
    }
    catch{
        Write-Verbose "Missing Package Manager, installing"
        $TempPath = "$env:TEMP\PSModules.zip"
        $NeededModules = 'PowerShellGet', 'PackageManagement'
        Remove-Item "$env:TEMP\PowerShellGetModules" -Recurse -Force -ErrorAction SilentlyContinue
        Invoke-RestMethod $ModuleDownloadURL -OutFile $TempPath
        Add-Type -Assembly "System.IO.Compression.Filesystem"
        [System.IO.Compression.ZipFile]::ExtractToDirectory($TempPath,$env:TEMP)

        if($Host.Version.Major -lt 5){
            foreach($Module in $NeededModules){
                Remove-Item "$env:ProgramFiles\WindowsPowerShell\Modules\$Module" -Recurse -Force -ErrorAction SilentlyContinue
                Get-ChildItem "$env:TEMP\PowerShellGetModules\$Module" | Get-ChildItem -Recurse | ForEach-Object{
                    Copy-Item $_.FullName "$env:ProgramFiles\WindowsPowerShell\Modules\$Module" -Force
                }
            }
        }
        else{
            foreach($Module in $NeededModules){
                Remove-Item "$env:ProgramFiles\WindowsPowerShell\Modules\$Module" -Recurse -Force -ErrorAction SilentlyContinue
                $null = New-Item "$env:ProgramFiles\WindowsPowerShell\Modules\$Module" -ItemType Directory -ErrorAction SilentlyContinue
                Copy-Item "$env:TEMP\PowerShellGetModules\$Module" "$env:ProgramFiles\WindowsPowerShell\Modules" -Force -Recurse
            }
        }

        Remove-Item $TempPath -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:TEMP\PowerShellGetModules" -Recurse -Force -ErrorAction SilentlyContinue

        foreach($Module in $NeededModules){
            $Found = $false
            $env:PSModulePath -split ';' | ForEach-Object{
                $Path = Join-Path $_ $Module
                if((Test-Path $Path)){
                    $Found = $true
                    Import-Module $Path
                }
            }
            if(!$Found){ Write-Error "Unable to find $Module" }
        }
    }

    try{ $null = Get-Command Get-PackageProvider -ErrorAction Stop }
    catch{ Redo-PowerShellGet }
    try{
        $Nuget = Get-PackageProvider NuGet -ListAvailable -ErrorAction Stop | Where-Object {$_.Version -gt $NuGetMinVersion}
    }
    catch{
        $null = Install-PackageProvider NuGet -MinimumVersion $NuGetMinVersion -Force
        $null = Install-Module PowershellGet -Force -Confirm:$false
    }
    if(!$Nuget){
        $null = Install-PackageProvider -Name Nuget -Force -Confirm:$false
    }

    try{ $null = Get-PSRepository 'PSGallery' -ErrorAction Stop }
    catch {
        if($_.exception.message -eq 'Invalid class'){
            Redo-PowerShellGet
        }
        else{
            Write-Verbose "Registering PSGallery."
            Remove-Item "$env:LOCALAPPDATA\Microsoft\windows\PowerShell\PowerShellGet\PSRepositories.xml" -ErrorAction SilentlyContinue
            Register-PSGallery
         }
    }

    if((Get-PSRepository 'PSGallery').InstallationPolicy -ne 'Trusted'){ Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted }
}
Initialize-PSGallery -ErrorAction Stop
