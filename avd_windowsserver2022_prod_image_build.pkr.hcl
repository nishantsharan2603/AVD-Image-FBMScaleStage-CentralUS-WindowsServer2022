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

variable "subscription_id" {}
variable "tenant_id" {}
variable "client_id" {}
variable "client_secret" {}

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

  communicator   = "winrm"
  winrm_use_ssl  = true
  winrm_insecure = true
  winrm_timeout  = "10m"
  winrm_username = "packer"

  build_resource_group_name = "fbm-avd-packerbuild01"

  shared_image_gallery_destination {
    subscription        = var.subscription_id
    resource_group      = "fbm-scale-americas-avd"
    gallery_name        = "acgazeasavdfbmscaleprod01"
    image_name          = "azure_windowsserver_2022_baseos_avd_24h2_prodeastus_gen2"
    image_version       = "16.2.2026" # <-- avoid leading zero in minor version
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
  ##############################################
  provisioner "powershell" {
    inline = [
      "$path = 'C:\\AVDImage'",
      "if (-not (Test-Path -Path $path)) { New-Item -ItemType Directory -Force -Path $path | Out-Null }",
      "$script = 'C:\\AVDImage\\AIB_WindowsServer_2022_ManhattanScale_CustomSettings.ps1'",
      "Invoke-WebRequest -Uri 'https://avdprodfbmscalestc01.blob.core.windows.net/sourcefbmscaleprod/AIB_WindowsServer_2022_ManhattanScale_CustomSettings.ps1' -OutFile $script",
      "Start-Sleep -Seconds 10",
      "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script"
    ]
    timeout          = "2h"
    valid_exit_codes = [0, 3010]
  }

  ##############################################
  # 2. Install Scale Applications - Step1
  ##############################################
  provisioner "powershell" {
    inline = [
      "$path = 'C:\\AVDImage'",
      "if (-not (Test-Path -Path $path)) { New-Item -ItemType Directory -Force -Path $path | Out-Null }",
      "$script = 'C:\\AVDImage\\AIB_WindowsServer_2022_ManhattanScale_InstallApps.ps1'",
      "Invoke-WebRequest -Uri 'https://avdprodfbmscalestc01.blob.core.windows.net/sourcefbmscaleprod/AIB_WindowsServer_2022_ManhattanScale_InstallApps.ps1' -OutFile $script",
      "Start-Sleep -Seconds 10",
      "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script"
    ]
    timeout          = "2h"
    valid_exit_codes = [0, 3010]
  }

  ##############################################
  # 3. Install Scale Applications - Step2
  ##############################################
  provisioner "powershell" {
    inline = [
      "$script = 'C:\\ManhattanAssociates\\ManhattanSCALE\\dsc.ps1'",
      "if (-not (Test-Path -Path $script)) { Write-Error \"Missing script: $script\"; exit 1 }",
      "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script"
    ]
    timeout          = "2h"
    valid_exit_codes = [0, 3010]
  }

  ##############################################
  # 4. Rebooting the VM
  ##############################################
  provisioner "powershell" {
    inline  = ["Write-Output 'Rebooting after step 3...'; Restart-Computer -Force"]
    timeout = "30m"
  }

  ##############################################
  # 5. Check if Local User ILSSRV exists in Admin Group
  ##############################################
  provisioner "powershell" {
    inline = [
      "$path = 'C:\\AVDImage'",
      "if (-not (Test-Path -Path $path)) { New-Item -ItemType Directory -Force -Path $path | Out-Null }",
      "$script = 'C:\\AVDImage\\AIB_WindowsServer_2022_ManhattanScale_LocalUserAdministratorVerify.ps1'",
      "Invoke-WebRequest -Uri 'https://avdprodfbmscalestc01.blob.core.windows.net/sourcefbmscaleprod/AIB_WindowsServer_2022_ManhattanScale_LocalUserAdministratorVerify.ps1' -OutFile $script",
      "Start-Sleep -Seconds 10",
      "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script"
    ]
    timeout          = "2h"
    valid_exit_codes = [0, 3010]
  }

  ##############################################
  # 6. NCACHE Installation
  ##############################################
  provisioner "powershell" {
    inline = [
      "$script = 'C:\\ManhattanAssociates\\ManhattanSCALE\\Ncache\\install.ps1'",
      "if (-not (Test-Path -Path $script)) { Write-Error \"Missing script: $script\"; exit 1 }",
      "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script"
    ]
    timeout          = "2h"
    valid_exit_codes = [0, 3010]
  }

  ##############################################
  # 7. Rebooting the VM
  ##############################################
  provisioner "powershell" {
    inline  = ["Write-Output 'Rebooting after NCACHE install...'; Restart-Computer -Force"]
    timeout = "30m"
  }

  ##############################################
  # 8. Import NCACHE Module & Start Cache
  ##############################################
  provisioner "powershell" {
    inline = [
      "$path = 'C:\\AVDImage'",
      "if (-not (Test-Path -Path $path)) { New-Item -ItemType Directory -Force -Path $path | Out-Null }",
      "$script1 = 'C:\\AVDImage\\AIB_WindowsServer_2022_ManhattanScale_ImportNcacheDLL.ps1'",
      "Invoke-WebRequest -Uri 'https://avdprodfbmscalestc01.blob.core.windows.net/sourcefbmscaleprod/AIB_WindowsServer_2022_ManhattanScale_ImportNcacheDLL.ps1' -OutFile $script1",
      "Start-Sleep -Seconds 10",
      "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script1",
      "Start-Sleep -Seconds 10",
      "$script2 = 'C:\\ManhattanAssociates\\ManhattanSCALE\\Ncache\\bin\\startcache.ps1'",
      "if (-not (Test-Path -Path $script2)) { Write-Error \"Missing script: $script2\"; exit 1 }",
      "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script2"
    ]
    timeout          = "2h"
    valid_exit_codes = [0, 3010]
  }

  ##############################################
  # 9. Windows Optimization
  ##############################################
  provisioner "powershell" {
    inline = [
      "$path = 'C:\\AVDImage3'",
      "if (-not (Test-Path -Path $path)) { New-Item -ItemType Directory -Force -Path $path | Out-Null }",
      "$script = 'C:\\AVDImage3\\windowsOptimization.ps1'",
      "Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/Azure/RDS-Templates/master/CustomImageTemplateScripts/CustomImageTemplateScripts_2024-03-27/WindowsOptimization.ps1' -OutFile $script",
      "Start-Sleep -Seconds 10",
      "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -ArgumentList '-Optimizations ''DefaultUserSettings'',''NetworkOptimizations'''"
    ]
    timeout          = "1h"
    valid_exit_codes = [0, 3010]
  }

  ##############################################
  # 10. Post-Optimization Windows Updates
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
  # 11. Reboot After Optimization
  ##############################################
  provisioner "powershell" {
    inline  = ["Write-Output 'Rebooting after optimizations...'; Restart-Computer -Force"]
    timeout = "30m"
  }

  ##############################################
  # 12. Disabling Unwanted Services
  ##############################################
  provisioner "powershell" {
    inline = [
      "$path = 'C:\\AVDImage'",
      "if (-not (Test-Path -Path $path)) { New-Item -ItemType Directory -Force -Path $path | Out-Null }",
      "$script = 'C:\\AVDImage\\AIB_AVD_DisableServices.ps1'",
      "Invoke-WebRequest -Uri 'https://avdprodfbmscalestc01.blob.core.windows.net/sourcefbmscaleprod/AIB_AVD_DisableServices.ps1' -OutFile $script",
      "Start-Sleep -Seconds 10",
      "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script"
    ]
    timeout          = "1h"
    valid_exit_codes = [0, 3010]
  }

  ##############################################
  # 13. Disabling Scheduled Task
  ##############################################
  provisioner "powershell" {
    inline = [
      "$path = 'C:\\AVDImage'",
      "if (-not (Test-Path -Path $path)) { New-Item -ItemType Directory -Force -Path $path | Out-Null }",
      "$script = 'C:\\AVDImage\\AIB_AVD_DisableScheduleTask.ps1'",
      "Invoke-WebRequest -Uri 'https://avdprodfbmscalestc01.blob.core.windows.net/sourcefbmscaleprod/AIB_AVD_DisableScheduleTask.ps1' -OutFile $script",
      "Start-Sleep -Seconds 10",
      "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script"
    ]
    timeout          = "1h"
    valid_exit_codes = [0, 3010]
  }

  ##############################################
  # 14. Disabling Windows Traces
  ##############################################
  provisioner "powershell" {
    inline = [
      "$path = 'C:\\AVDImage'",
      "if (-not (Test-Path -Path $path)) { New-Item -ItemType Directory -Force -Path $path | Out-Null }",
      "$script = 'C:\\AVDImage\\AIB_AVD_DisableWindowsTraces.ps1'",
      "Invoke-WebRequest -Uri 'https://avdprodfbmscalestc01.blob.core.windows.net/sourcefbmscaleprod/AIB_AVD_DisableWindowsTraces.ps1' -OutFile $script",
      "Start-Sleep -Seconds 10",
      "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script"
    ]
    timeout          = "1h"
    valid_exit_codes = [0, 3010]
  }

  ##############################################
  # 15. Lanman Parameters
  ##############################################
  provisioner "powershell" {
    inline = [
      "$path = 'C:\\AVDImage'",
      "if (-not (Test-Path -Path $path)) { New-Item -ItemType Directory -Force -Path $path | Out-Null }",
      "$script = 'C:\\AVDImage\\AIB_AVD_LanmanParameters.ps1'",
      "Invoke-WebRequest -Uri 'https://avdprodfbmscalestc01.blob.core.windows.net/sourcefbmscaleprod/AIB_AVD_LanmanParameters.ps1' -OutFile $script",
      "Start-Sleep -Seconds 10",
      "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script"
    ]
    timeout          = "1h"
    valid_exit_codes = [0, 3010]
  }

  ##############################################
  # 16. Remove UWP Apps
  ##############################################
  provisioner "powershell" {
    inline = [
      "$path = 'C:\\AVDImage'",
      "if (-not (Test-Path -Path $path)) { New-Item -ItemType Directory -Force -Path $path | Out-Null }",
      "$script = 'C:\\AVDImage\\AIB_AVD_UWPRemoval.ps1'",
      "Invoke-WebRequest -Uri 'https://avdprodfbmscalestc01.blob.core.windows.net/sourcefbmscaleprod/AIB_AVD_UWPRemoval.ps1' -OutFile $script",
      "Start-Sleep -Seconds 10",
      "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script"
    ]
    timeout          = "1h"
    valid_exit_codes = [0, 3010]
  }

  ##############################################
  # 17. Security Hardening of the Image
  ##############################################
  provisioner "powershell" {
    inline = [
      "$path = 'C:\\AVDImage'",
      "if (-not (Test-Path -Path $path)) { New-Item -ItemType Directory -Force -Path $path | Out-Null }",
      "$script = 'C:\\AVDImage\\AIB_AVD_SecurityHardening.ps1'",
      "Invoke-WebRequest -Uri 'https://avdprodfbmscalestc01.blob.core.windows.net/sourcefbmscaleprod/AIB_AVD_SecurityHardening.ps1' -OutFile $script",
      "Start-Sleep -Seconds 10",
      "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script"
    ]
    timeout          = "1h"
    valid_exit_codes = [0, 3010]
  }

  ##############################################
  # 18. Install Security Tools
  ##############################################
  provisioner "powershell" {
    inline = [
      "$path = 'C:\\AVDImage'",
      "if (-not (Test-Path -Path $path)) { New-Item -ItemType Directory -Force -Path $path | Out-Null }",
      "$script = 'C:\\AVDImage\\AIB_AVD_SecurityToolInstallation_Nov.ps1'",
      "Invoke-WebRequest -Uri 'https://avdprodfbmscalestc01.blob.core.windows.net/sourcefbmscaleprod/AIB_AVD_SecurityToolInstallation_Nov.ps1' -OutFile $script",
      "Start-Sleep -Seconds 10",
      "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script"
    ]
    timeout          = "2h"
    valid_exit_codes = [0, 3010]
  }

  ##############################################
  # 19. Cleanup Image Build Artifacts
  ##############################################
  provisioner "powershell" {
    inline = [
      "foreach ($p in 'C:\\AVDImage','C:\\AVDImage1','C:\\AVDImage2','C:\\AVDImage3') { if (Test-Path -Path $p) { Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue } }",
      "$cleanup = 'D:\\AIB_AVD_DiskCleanup.ps1'",
      "Invoke-WebRequest -Uri 'https://avdprodfbmscalestc01.blob.core.windows.net/sourcefbmscaleprod/AIB_AVD_DiskCleanup.ps1' -OutFile $cleanup",
      "Start-Sleep -Seconds 10",
      "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cleanup"
    ]
    timeout          = "2h"
    valid_exit_codes = [0, 3010]
  }

  ##############################################
  # 20. Run Admin SysPrep
  ##############################################
  provisioner "powershell" {
    inline = [
      "while ((Get-Service RdAgent).Status -ne 'Running') { Start-Sleep -Seconds 5 }",
      "while ((Get-Service WindowsAzureGuestAgent).Status -ne 'Running') { Start-Sleep -Seconds 5 }",
