param(
    [parameter(Mandatory=$true)]
    [String] $GopathBuildDir,
    [parameter(Mandatory=$true)]
    [String] $DockerTestsGitRepo,
    [parameter(Mandatory=$true)]
    [String] $DockerTestsGitBranch,
    [parameter(Mandatory=$true)]
    [String] $SmbSharePath,
    [parameter(Mandatory=$true)]
    [String] $SmbShareUser,
    [parameter(Mandatory=$true)]
    [String] $SmbSharePass,
    [parameter(Mandatory=$true)]
    [String] $DockerClientPath,
    [parameter(Mandatory=$true)]
    [String] $DBConfFilePath
)

$ErrorActionPreference = "Stop"

$SERVICE_WRAPPER_PATH = "C:\service_wrapper.exe"
$DOCKER_DATA_PATH = "C:\lcow"
$LinuxContainersPath = "C:\Program Files\Linux Containers"


function Register-DockerdService {
    param(
        [String] $BuildPath
    )

    $env:LCOW_SUPPORTED = "1"
    $env:DOCKER_DEFAULT_PLATFORM = "linux"
    Write-Host $env:LCOW_SUPPORTED
    Write-Host $env:LCOW_API_PLATFORM_IF_OMITTED

    if (Test-Path $DOCKER_DATA_PATH ) {
        Remove-Item $DOCKER_DATA_PATH -Force -Recurse
        New-Item $DOCKER_DATA_PATH -ItemType Directory
    } else {
        New-Item $DOCKER_DATA_PATH -ItemType Directory
    }

    try {
        pushd "$BuildPath\docker\bundles\"
        New-Service -Name "dockerd" -BinaryPathName `
            "${SERVICE_WRAPPER_PATH} dockerd $BuildPath\docker\bundles\dockerd.exe -D --experimental --data-root ${DOCKER_DATA_PATH}"
        Write-Host "Docker service registration ran successfully"
        popd
    } catch {
        Write-Host "Cannot start Docker service"
        exit 1
    }
}

function Start-DockerdService {
    Start-Service dockerd

    $service = Get-Service dockerd
    if ($service.Status -ne 'Running') {
        Write-Host "Dockerd service not running"
        exit 1
    } else {
        Write-Host "Dockerd service started successfully"
        Start-Sleep 10
    }
}

function Start-DockerTests {
    param(
        [String] $ClientPath,
        [String] $BuildPath
    )

    pushd $BuildPath
    $env:PATH += $ClientPath
    Write-Host $env:PATH

    pushd docker_tests
    & ./runTests.ps1 yes

    Write-Host "Docker tests ran successfully"

    try {
        if (!(Test-Path "${env:WORKSPACE}\\results")) {
            New-Item "${env:WORKSPACE}\\results" -ItemType Directory
        }
        Get-Content .\tests.json | Out-file -Encoding "Default" "${env:WORKSPACE}\results\tests.json"
        Get-Content .\tests.log | Out-file -Encoding "Default" "${env:WORKSPACE}\results\tests.log"
    } catch {
        Write-Host "Could not copy the logs to the workspace dir!"
    }

    Get-Content .\tests.json | Out-file -Encoding "Default" `
        "${env:WORKSPACE}\scripts\linux_containers_on_windows\db_parser\tests.json"
    popd
    popd
}

function Copy-Artifacts {
    Param(
        [string] $ArtifactPath,
        [string] $Destination
    )

    if (Test-Path $Destination) {
        Get-ChildItem -Path $Destination -Include *.* -File -Recurse | foreach { $_.Delete()}
    } else {
        Write-Host "Directory $destination does not exist, we try to create it."
        New-Item $Destination -ItemType Directory -ErrorAction SilentlyContinue
    }

    $initrdImagePath = Join-Path $Destination "initrd.img"
    Copy-Item "$ArtifactPath\initrd_artifact\initrd.img" $initrdImagePath -Force
    if ($LastExitCode) {
        throw "Cannot copy $ArtifactPath\initrd_artifact\initrd.img to $initrdImagePath"
    } else {
        Write-Host "Initrd artifact copied from $ArtifactPath\initrd_artifact\initrd.img to $initrdImagePath successfully"
    }

    $kernelImagePath = Join-Path $Destination "kernel"
    Copy-Item "$ArtifactPath\bootx64.efi" $kernelImagePath -Force
    if ($LastExitCode) {
        throw "Cannot copy and rename $ArtifactPath\bootx64.efi to $kernelImagePath"
    } else {
        Write-Host "bootx64.efi artifact copied and renamed from $ArtifactPath\bootx64.efi to $kernelImagePath successfully"
    }
    Write-Host "Artifacts copied successfully"
}

function Clean-Up {
    if (Get-Service "dockerd" -ErrorAction SilentlyContinue) {
        Stop-Service "dockerd"
        sc.exe delete "dockerd"
    }
}


function Mount-SMBShare {
    param(
        [String] $SharedStoragePath,
        [String] $ShareUser,
        [String] $SharePassword
    )

    # Note(avladu): Replace backslashes with forward slashes
    # for Windows compat
    $SharedStoragePath = $SharedStoragePath.replace('/', '\')

    # Note(avladu): Sometimes, SMB mappings enter into an
    # "Unavailable" state and need to be removed, as they cannot be
    # accessed anymore.
    $smbMappingsUnavailable = Get-SmbMapping -RemotePath $SharedStoragePath `
        -ErrorAction SilentlyContinue | `
        Where-Object {$_.Status -ne "Ok"}
    if ($smbMappingsUnavailable) {
        foreach ($smbMappingUnavailable in $smbMappingsUnavailable) {
            $output = net use /delete $smbMappingUnavailable.LocalPath 2>&1
        }
    }

    $mountPoint = $null
    $smbMapping = Get-SmbMapping -RemotePath $SharedStoragePath `
        -ErrorAction SilentlyContinue
    if ($smbMapping) {
        if ($smbMapping.LocalPath -is [array]){
            return $smbMapping.LocalPath[0]
        } else {
            return $smbMapping.LocalPath
        }
    }
    for ([byte]$c = [char]'G'; $c -le [char]'Z'; $c++) {
        $mountPoint = [char]$c + ":"
        try {
            $netOutput = net.exe use $mountPoint $SharedStoragePath `
                /u:"AZURE\$ShareUser" "$SharePassword" 2>&1
            if ($LASTEXITCODE) {
                throw ("Failed to mount share {0} to {1} with error {2}" `
                    -f @($SharedStoragePath, $mountPoint, $netOutput))
            } else {
                Get-PSDrive | Out-Null
                Get-SmbMapping | Out-Null
                return $mountPoint
            }
        } catch {
            if ($_ -like "*System error 67 has occurred.*") {
                throw $_
            }
        }
    }
    if (!$mountPoint) {
        Write-Host $Error[0]
        throw "Failed to mount $SharedStoragePath to $mountPoint"
    }
}
function Publish-ToPowerBI {
    param(
        [String] $DBConfFilePath
    )
    pushd "${env:WORKSPACE}\scripts\linux_containers_on_windows\db_parser"
    pip install -r requirements.txt

    Copy-Item -Path $DBConfFilePath -Destination .

    python parser.py
    if ($LastExitCode) {
        throw "Could not publish test results to PowerBI"
    } else {
        Write-Host "Test results published successfully to PowerBI"
    }
}

function Main {
    $GopathBuildDir = Join-Path $env:SystemDrive $GopathBuildDir
    $DockerClientPath = ";${env:SystemDrive}\$DockerClientPath"

    $currentPath = (Get-Item -Path ".\" -Verbose).FullName
    $currentPath = "$currentPath\artifacts"

    $mountPath = Mount-SMBShare $SmbSharePath $SmbShareUser $SmbSharePass
    Write-Host "Mount point is: $mountPath"
    $artifactsPath = "$mountPath\lcow_builds\"
    Write-Host "Mount path is: $artifactsPath"

    cd $artifactsPath
    $latestBuildPath = Get-ChildItem -Directory | `
        Where-Object {$_.Name.contains("kernel")} | `
        Sort-Object -Descending -Property CreationTime | Select-Object -First 1
    
    cd $latestBuildPath
    $buildFullPath = (Get-Item -Path ".\" -Verbose).FullName
    popd
    Write-Host "Artifact full path is: $buildFullPath"

    Clean-Up
    Copy-Artifacts $buildFullPath $LinuxContainersPath
    Copy-Artifacts $buildFullPath $currentPath

    Register-DockerdService $GopathBuildDir

    Start-DockerdService
    Start-DockerTests $DockerClientPath $GopathBuildDir $buildFullPath

    try {
        Publish-ToPowerBI $DBConfFilePath
    } catch {
        Write-Host "Could not publish test results to PowerBI"
    }
}

Main
