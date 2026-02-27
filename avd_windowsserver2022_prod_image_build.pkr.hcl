packer {
  required_version = ">= 1.9.0"

  required_plugins {
    azure = {
      version = ">= 1.8.0"
      source  = "github.com/hashicorp/azure"
    }
    windows-update = {
      version = ">= 0.14.1"
      source  = "github.com/rgl/windows-update"
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Variables - values injected via PKR_VAR_* from GitHub Actions secrets
# Nothing sensitive is hardcoded here
# ─────────────────────────────────────────────────────────────────────────────
variable "subscription_id"     {}
variable "tenant_id"           {}
variable "client_id"           {}
variable "client_secret"       { sensitive = true }
variable "ilssrv_password"     { sensitive = true }
variable "db_baseline_connstr" { sensitive = true }
variable "db_scalesys_connstr" { sensitive = true }
variable "ncache_server_ips"   { default   = "180.16.64.4,180.16.64.5" }

source "azure-arm" "windowsserver2022_avd_manhattanscale" {
    subscription_id = var.subscription_id
    tenant_id       = var.tenant_id
    client_id       = var.client_id
    client_secret   = var.client_secret
    os_type         = "Windows"
    image_publisher = "microsoftwindowsserver"
    image_offer     = "windowsserver"
    image_sku       = "2022-datacenter-azure-edition"
    image_version   = "latest"
    vm_size         = "Standard_E8ds_v5"
    os_disk_size_gb = 127
    communicator    = "winrm"
    winrm_use_ssl   = true
    winrm_insecure  = true
    winrm_timeout   = "10m"
    winrm_username  = "packer"
    build_resource_group_name = "fbm-avd-packerbuild01"

    shared_image_gallery_destination {
        subscription        = var.subscription_id
        resource_group      = "fbm-scale-americas-avd"
        gallery_name        = "acgazeasavdfbmscaleprod01"
        image_name          = "azure_windowsserver_2022_baseos_avd_24h2_prodeastus_gen2"
        image_version       = "16.02.2026"
        replication_regions = ["eastus", "centralus"]
    }

    azure_tags = {
        AVDAZServices = "AVD Components"
        Environment   = "Production"
        Owner         = "AVDTeam"
    }
}

build {
    name    = "AVD_WindowsServer_2022_Image_Build"
    sources = ["source.azure-arm.windowsserver2022_avd_manhattanscale"]

  ##############################################
  # 1. Apply Custom AVD Settings
  # Runs as SYSTEM (packer account)
  # Sets RDS timeouts, IE ESC, firewall rules,
  # downloads and extracts Scale2024.zip
  ##############################################
    provisioner "powershell" {
        inline = [
            "$path = 'C:\\AVDImage'",
            "If(!(Test-Path $path)) { New-Item -ItemType Directory -Force -Path $path }",
            "cd C:\\AVDImage",
            "Invoke-WebRequest -Uri 'https://avdprodfbmscalestc01.blob.core.windows.net/sourcefbmscaleprod/AIB_WindowsServer_2022_ManhattanScale_CustomSettings.ps1' -OutFile 'C:\\AVDImage\\AIB_WindowsServer_2022_ManhattanScale_CustomSettings.ps1'",
            "Start-Sleep -Seconds 30",
            "& .\\AIB_WindowsServer_2022_ManhattanScale_CustomSettings.ps1"
        ]
        timeout          = "2h"
        valid_exit_codes = [0, 3010]
    }

  ##############################################
  # 2. Create ILSSRV Local User
  # Runs as SYSTEM (packer account)
  # Creates user, adds to Administrators,
  # grants Log on as a service
  ##############################################
    provisioner "powershell" {
        environment_vars = [
            "ILSSRV_PASSWORD=${var.ilssrv_password}"
        ]
        inline = [
            "$path = 'C:\\AVDImage'",
            "If(!(Test-Path $path)) { New-Item -ItemType Directory -Force -Path $path }",
            "cd C:\\AVDImage",
            "Invoke-WebRequest -Uri 'https://avdprodfbmscalestc01.blob.core.windows.net/sourcefbmscaleprod/AIB_WindowsServer_2022_ManhattanScale_CreateILSSRV.ps1' -OutFile 'C:\\AVDImage\\AIB_WindowsServer_2022_ManhattanScale_CreateILSSRV.ps1'",
            "Start-Sleep -Seconds 30",
            "& .\\AIB_WindowsServer_2022_ManhattanScale_CreateILSSRV.ps1"
        ]
        timeout          = "30m"
        valid_exit_codes = [0]
    }

  ##############################################
  # 3. Install Scale Applications - AIM
  # Runs as SYSTEM
  ##############################################
    provisioner "powershell" {
        inline = [
            "$path = 'C:\\AVDImage'",
            "If(!(Test-Path $path)) { New-Item -ItemType Directory -Force -Path $path }",
            "cd C:\\AVDImage",
            "Invoke-WebRequest -Uri 'https://avdprodfbmscalestc01.blob.core.windows.net/sourcefbmscaleprod/AIB_WindowsServer_2022_ManhattanScale_InstallApps.ps1' -OutFile 'C:\\AVDImage\\AIB_WindowsServer_2022_ManhattanScale_InstallApps.ps1'",
            "Start-Sleep -Seconds 30",
            "& .\\AIB_WindowsServer_2022_ManhattanScale_InstallApps.ps1"
        ]
        timeout          = "2h"
        valid_exit_codes = [0, 3010]
    }

  ##############################################
  # 4. Run dsc.ps1 as ILSSRV
  # elevated_user = ILSSRV tells Packer to run
  # this provisioner under ILSSRV's credentials
  # No wrapper script needed
  ##############################################
    provisioner "powershell" {
        elevated_user     = "ILSSRV"
        elevated_password = var.ilssrv_password
        inline = [
            "$path = 'C:\\AVDImage'",
            "If(!(Test-Path $path)) { New-Item -ItemType Directory -Force -Path $path }",
            "cd C:\\AVDImage",
            "Invoke-WebRequest -Uri 'https://avdprodfbmscalestc01.blob.core.windows.net/sourcefbmscaleprod/AIB_WindowsServer_2022_ManhattanScale_DSC.ps1' -OutFile 'C:\\AVDImage\\AIB_WindowsServer_2022_ManhattanScale_DSC.ps1'",
            "Start-Sleep -Seconds 30",
            "& .\\AIB_WindowsServer_2022_ManhattanScale_DSC.ps1"
        ]
        timeout          = "2h"
        valid_exit_codes = [0, 3010]
    }

  ##############################################
  # 5. Reboot after DSC
  ##############################################
    provisioner "windows-restart" {
        restart_timeout = "20m"
    }

  ##############################################
  # 6. Post-Reboot: Verify ILSSRV still in Administrators
  # Runs as SYSTEM
  ##############################################
    provisioner "powershell" {
        inline = [
            "$path = 'C:\\AVDImage'",
            "If(!(Test-Path $path)) { New-Item -ItemType Directory -Force -Path $path }",
            "cd C:\\AVDImage",
            "Invoke-WebRequest -Uri 'https://avdprodfbmscalestc01.blob.core.windows.net/sourcefbmscaleprod/AIB_WindowsServer_2022_ManhattanScale_LocalUserAdministratorVerify.ps1' -OutFile 'C:\\AVDImage\\AIB_WindowsServer_2022_ManhattanScale_LocalUserAdministratorVerify.ps1'",
            "Start-Sleep -Seconds 30",
            "& .\\AIB_WindowsServer_2022_ManhattanScale_LocalUserAdministratorVerify.ps1"
        ]
        timeout          = "15m"
        valid_exit_codes = [0, 10]
    }

  ##############################################
  # 7. Patch NCache config with app server IPs
  # Runs as SYSTEM
  ##############################################
    provisioner "powershell" {
        environment_vars = [
            "NCACHE_SERVER_IPS=${var.ncache_server_ips}"
        ]
        inline = [
            "$path = 'C:\\AVDImage'",
            "If(!(Test-Path $path)) { New-Item -ItemType Directory -Force -Path $path }",
            "cd C:\\AVDImage",
            "Invoke-WebRequest -Uri 'https://avdprodfbmscalestc01.blob.core.windows.net/sourcefbmscaleprod/AIB_WindowsServer_2022_ManhattanScale_NCacheConfig.ps1' -OutFile 'C:\\AVDImage\\AIB_WindowsServer_2022_ManhattanScale_NCacheConfig.ps1'",
            "Start-Sleep -Seconds 30",
            "& .\\AIB_WindowsServer_2022_ManhattanScale_NCacheConfig.ps1"
        ]
        timeout          = "30m"
        valid_exit_codes = [0]
    }

  ##############################################
  # 8. Install and Start NCache as ILSSRV
  # elevated_user = ILSSRV
  ##############################################
    provisioner "powershell" {
        elevated_user     = "ILSSRV"
        elevated_password = var.ilssrv_password
        inline = [
            "$path = 'C:\\AVDImage'",
            "If(!(Test-Path $path)) { New-Item -ItemType Directory -Force -Path $path }",
            "cd C:\\AVDImage",
            "Invoke-WebRequest -Uri 'https://avdprodfbmscalestc01.blob.core.windows.net/sourcefbmscaleprod/AIB_WindowsServer_2022_ManhattanScale_NCacheInstall.ps1' -OutFile 'C:\\AVDImage\\AIB_WindowsServer_2022_ManhattanScale_NCacheInstall.ps1'",
            "Start-Sleep -Seconds 30",
            "& .\\AIB_WindowsServer_2022_ManhattanScale_NCacheInstall.ps1"
        ]
        timeout          = "1h"
        valid_exit_codes = [0]
    }

  ##############################################
  # 9. Import NCache DLL and verify caches
  # Runs as SYSTEM
  ##############################################
    provisioner "powershell" {
        inline = [
            "$path = 'C:\\AVDImage'",
            "If(!(Test-Path $path)) { New-Item -ItemType Directory -Force -Path $path }",
            "cd C:\\AVDImage",
            "Invoke-WebRequest -Uri 'https://avdprodfbmscalestc01.blob.core.windows.net/sourcefbmscaleprod/AIB_WindowsServer_2022_ManhattanScale_ImportNcacheDLL.ps1' -OutFile 'C:\\AVDImage\\AIB_WindowsServer_2022_ManhattanScale_ImportNcacheDLL.ps1'",
            "Start-Sleep -Seconds 30",
            "& .\\AIB_WindowsServer_2022_ManhattanScale_ImportNcacheDLL.ps1"
        ]
        timeout          = "30m"
        valid_exit_codes = [0, 3010]
    }

  ##############################################
  # 10. Install Manhattan SCALE as ILSSRV
  # elevated_user = ILSSRV
  # DB connection strings injected via environment_vars
  ##############################################
    provisioner "powershell" {
        elevated_user     = "ILSSRV"
        elevated_password = var.ilssrv_password
        environment_vars  = [
            "DB_BASELINE_CONNSTR=${var.db_baseline_connstr}",
            "DB_SCALESYS_CONNSTR=${var.db_scalesys_connstr}"
        ]
        inline = [
            "$path = 'C:\\AVDImage'",
            "If(!(Test-Path $path)) { New-Item -ItemType Directory -Force -Path $path }",
            "cd C:\\AVDImage",
            "Invoke-WebRequest -Uri 'https://avdprodfbmscalestc01.blob.core.windows.net/sourcefbmscaleprod/AIB_WindowsServer_2022_ManhattanScale_InstallScale.ps1' -OutFile 'C:\\AVDImage\\AIB_WindowsServer_2022_ManhattanScale_InstallScale.ps1'",
            "Start-Sleep -Seconds 30",
            "& .\\AIB_WindowsServer_2022_ManhattanScale_InstallScale.ps1"
        ]
        timeout          = "2h"
        valid_exit_codes = [0]
    }

  ##############################################
  # 11. Re-verify ILSSRV group after Scale install
  # Runs as SYSTEM
  ##############################################
    provisioner "powershell" {
        inline = [
            "cd C:\\AVDImage",
            "& .\\AIB_WindowsServer_2022_ManhattanScale_LocalUserAdministratorVerify.ps1"
        ]
        timeout          = "15m"
        valid_exit_codes = [0, 10]
    }

  ##############################################
  # 12. Windows Optimization
  # Runs as SYSTEM
  ##############################################
    provisioner "powershell" {
        inline = [
            "$path = 'C:\\AVDImage3'",
            "If(!(Test-Path $path)) { New-Item -ItemType Directory -Force -Path $path }",
            "cd C:\\AVDImage3",
            "Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/Azure/RDS-Templates/master/CustomImageTemplateScripts/CustomImageTemplateScripts_2024-03-27/WindowsOptimization.ps1' -OutFile 'C:\\AVDImage3\\windowsOptimization.ps1'",
            "Start-Sleep -Seconds 30",
            "& .\\windowsOptimization.ps1 -Optimizations 'DefaultUserSettings','NetworkOptimizations'"
        ]
        timeout          = "1h"
        valid_exit_codes = [0, 3010]
    }

  ##############################################
  # 13. Post-Optimization Windows Updates
  ##############################################
    provisioner "windows-update" {
        search_criteria = "IsInstalled=0"
        filters = [
            "exclude:$_.Title -like '*Preview*'",
            "include:$true"
        ]
        update_limit = 100
    }

  ##############################################
  # 14. Reboot After Updates
  ##############################################
    provisioner "windows-restart" {
        restart_timeout = "20m"
    }

  ##############################################
  # 15. Disable Unwanted Services
  ##############################################
    provisioner "powershell" {
        inline = [
            "$path = 'C:\\AVDImage'",
            "If(!(Test-Path $path)) { New-Item -ItemType Directory -Force -Path $path }",
            "cd C:\\AVDImage",
            "Invoke-WebRequest -Uri 'https://avdprodfbmscalestc01.blob.core.windows.net/sourcefbmscaleprod/AIB_AVD_DisableServices.ps1' -OutFile 'C:\\AVDImage\\AIB_AVD_DisableServices.ps1'",
            "Start-Sleep -Seconds 30",
            "& .\\AIB_AVD_DisableServices.ps1"
        ]
        timeout          = "1h"
        valid_exit_codes = [0, 3010]
    }

  ##############################################
  # 16. Disable Scheduled Tasks
  ##############################################
    provisioner "powershell" {
        inline = [
            "$path = 'C:\\AVDImage'",
            "If(!(Test-Path $path)) { New-Item -ItemType Directory -Force -Path $path }",
            "cd C:\\AVDImage",
            "Invoke-WebRequest -Uri 'https://avdprodfbmscalestc01.blob.core.windows.net/sourcefbmscaleprod/AIB_AVD_DisableScheduleTask.ps1' -OutFile 'C:\\AVDImage\\AIB_AVD_DisableScheduleTask.ps1'",
            "Start-Sleep -Seconds 30",
            "& .\\AIB_AVD_DisableScheduleTask.ps1"
        ]
        timeout          = "1h"
        valid_exit_codes = [0, 3010]
    }

  ##############################################
  # 17. Disable Windows Traces
  ##############################################
    provisioner "powershell" {
        inline = [
            "$path = 'C:\\AVDImage'",
            "If(!(Test-Path $path)) { New-Item -ItemType Directory -Force -Path $path }",
            "cd C:\\AVDImage",
            "Invoke-WebRequest -Uri 'https://avdprodfbmscalestc01.blob.core.windows.net/sourcefbmscaleprod/AIB_AVD_DisableWindowsTraces.ps1' -OutFile 'C:\\AVDImage\\AIB_AVD_DisableWindowsTraces.ps1'",
            "Start-Sleep -Seconds 30",
            "& .\\AIB_AVD_DisableWindowsTraces.ps1"
        ]
        timeout          = "1h"
        valid_exit_codes = [0, 3010]
    }

  ##############################################
  # 18. Lanman Parameters
  ##############################################
    provisioner "powershell" {
        inline = [
            "$path = 'C:\\AVDImage'",
            "If(!(Test-Path $path)) { New-Item -ItemType Directory -Force -Path $path }",
            "cd C:\\AVDImage",
            "Invoke-WebRequest -Uri 'https://avdprodfbmscalestc01.blob.core.windows.net/sourcefbmscaleprod/AIB_AVD_LanmanParameters.ps1' -OutFile 'C:\\AVDImage\\AIB_AVD_LanmanParameters.ps1'",
            "Start-Sleep -Seconds 30",
            "& .\\AIB_AVD_LanmanParameters.ps1"
        ]
        timeout          = "1h"
        valid_exit_codes = [0, 3010]
    }

  ##############################################
  # 19. Remove UWP Apps
  ##############################################
    provisioner "powershell" {
        inline = [
            "$path = 'C:\\AVDImage'",
            "If(!(Test-Path $path)) { New-Item -ItemType Directory -Force -Path $path }",
            "cd C:\\AVDImage",
            "Invoke-WebRequest -Uri 'https://avdprodfbmscalestc01.blob.core.windows.net/sourcefbmscaleprod/AIB_AVD_UWPRemoval.ps1' -OutFile 'C:\\AVDImage\\AIB_AVD_UWPRemoval.ps1'",
            "Start-Sleep -Seconds 30",
            "& .\\AIB_AVD_UWPRemoval.ps1"
        ]
        timeout          = "1h"
        valid_exit_codes = [0, 3010]
    }

  ##############################################
  # 20. Security Hardening
  ##############################################
    provisioner "powershell" {
        inline = [
            "$path = 'C:\\AVDImage'",
            "If(!(Test-Path $path)) { New-Item -ItemType Directory -Force -Path $path }",
            "cd C:\\AVDImage",
            "Invoke-WebRequest -Uri 'https://avdprodfbmscalestc01.blob.core.windows.net/sourcefbmscaleprod/AIB_AVD_SecurityHardening.ps1' -OutFile 'C:\\AVDImage\\AIB_AVD_SecurityHardening.ps1'",
            "Start-Sleep -Seconds 30",
            "& .\\AIB_AVD_SecurityHardening.ps1"
        ]
        timeout          = "1h"
        valid_exit_codes = [0, 3010]
    }

  ##############################################
  # 21. Install Security Tools
  ##############################################
    provisioner "powershell" {
        inline = [
            "$path = 'C:\\AVDImage'",
            "If(!(Test-Path $path)) { New-Item -ItemType Directory -Force -Path $path }",
            "cd C:\\AVDImage",
            "Invoke-WebRequest -Uri 'https://avdprodfbmscalestc01.blob.core.windows.net/sourcefbmscaleprod/AIB_AVD_SecurityToolInstallation_Nov.ps1' -OutFile 'C:\\AVDImage\\AIB_AVD_SecurityToolInstallation_Nov.ps1'",
            "Start-Sleep -Seconds 30",
            "& .\\AIB_AVD_SecurityToolInstallation_Nov.ps1"
        ]
        timeout          = "2h"
        valid_exit_codes = [0, 3010]
    }

  ##############################################
  # 22. Cleanup Image Build Artifacts
  ##############################################
    provisioner "powershell" {
        inline = [
            "$path1 = 'C:\\AVDImage'",
            "If((Test-Path $path1)) { Remove-Item -Path $path1 -Recurse -Force -ErrorAction SilentlyContinue }",
            "$path2 = 'C:\\AVDImage1'",
            "If((Test-Path $path2)) { Remove-Item -Path $path2 -Recurse -Force -ErrorAction SilentlyContinue }",
            "$path3 = 'C:\\AVDImage2'",
            "If((Test-Path $path3)) { Remove-Item -Path $path3 -Recurse -Force -ErrorAction SilentlyContinue }",
            "$path4 = 'C:\\AVDImage3'",
            "If((Test-Path $path4)) { Remove-Item -Path $path4 -Recurse -Force -ErrorAction SilentlyContinue }",
            "cd D:\\",
            "Invoke-WebRequest -Uri 'https://avdprodfbmscalestc01.blob.core.windows.net/sourcefbmscaleprod/AIB_AVD_DiskCleanup.ps1' -OutFile 'D:\\AIB_AVD_DiskCleanup.ps1'",
            "Start-Sleep -Seconds 30",
            "& .\\AIB_AVD_DiskCleanup.ps1"
        ]
        timeout          = "2h"
        valid_exit_codes = [0, 3010]
    }

  ##############################################
  # 23. Sysprep / Generalize
  ##############################################
    provisioner "powershell" {
        inline = [
            "while ((Get-Service RdAgent).Status -ne 'Running') { Start-Sleep -s 5 }",
            "while ((Get-Service WindowsAzureGuestAgent).Status -ne 'Running') { Start-Sleep -s 5 }",
            "& $env:SystemRoot\\System32\\Sysprep\\Sysprep.exe /oobe /generalize /quiet /quit /mode:vm",
            "while($true) { $imageState = Get-ItemProperty HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Setup\\State | Select ImageState; if($imageState.ImageState -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { Write-Output $imageState.ImageState; Start-Sleep -s 10 } else { break } }"
        ]
        timeout          = "3h"
        valid_exit_codes = [0, 3010]
    }
}
