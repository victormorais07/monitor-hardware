# Instala o Monitor de Hardware:
#   1. baixa o LibreHardwareMonitor (versao fixa, com o hash conferido) para a pasta lib
#   2. cria a tarefa agendada "Monitor de Hardware", que abre o widget como administrador sem pedir UAC
#   3. cria o atalho "Monitor de Hardware" no Menu Iniciar
#
# Uso:
#   .\instalar.ps1                      instala
#   .\instalar.ps1 -IniciarComWindows   instala e abre o widget sozinho ao entrar no Windows
#   .\instalar.ps1 -SoBaixar            so baixa a biblioteca (sem tarefa nem atalho)
#   .\instalar.ps1 -Desinstalar         remove a tarefa e o atalho
param(
    [switch]$IniciarComWindows,
    [switch]$SoBaixar,
    [switch]$Desinstalar,
    [switch]$Elevado   # uso interno: indica que o script ja foi reaberto como administrador
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$versao = '0.9.6'
$url = "https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases/download/v$versao/LibreHardwareMonitor.zip"
$sha256 = '086D9F1B5A99E643EDC2CFAAAC16051685B551E4C5AC0B32A57C58C0E529C001'

$raiz = $PSScriptRoot
$lib = Join-Path $raiz 'lib'
$dll = Join-Path $lib 'LibreHardwareMonitorLib.dll'
$vbs = Join-Path $raiz 'Iniciar-Monitor.vbs'
$tarefa = 'Monitor de Hardware'
$atalho = Join-Path ([Environment]::GetFolderPath('Programs')) 'Monitor de Hardware.lnk'

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Install-Biblioteca {
    if ((Test-Path $dll) -and (Get-Item $dll).VersionInfo.ProductVersion -like "$versao*") {
        Write-Host "LibreHardwareMonitor $versao ja esta na pasta lib."
        return
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $zip = Join-Path $env:TEMP "LibreHardwareMonitor-$versao.zip"
    Write-Host "Baixando LibreHardwareMonitor $versao..."
    Invoke-WebRequest $url -OutFile $zip -UseBasicParsing
    $hash = (Get-FileHash $zip -Algorithm SHA256).Hash
    if ($hash -ne $sha256) {
        Remove-Item $zip
        throw "O hash do arquivo baixado nao confere (veio $hash). Instalacao cancelada."
    }
    if (Test-Path $lib) { Remove-Item $lib -Recurse -Force }
    Expand-Archive $zip $lib
    Get-ChildItem $lib -Recurse -File | Unblock-File
    Remove-Item $zip
    Write-Host "Biblioteca extraida em $lib"
}

function Install-Tarefa {
    $usuario = "$env:USERDOMAIN\$env:USERNAME"
    $acao = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`""
    $principal = New-ScheduledTaskPrincipal -UserId $usuario -LogonType Interactive -RunLevel Highest
    $config = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $gatilhos = @()
    if ($IniciarComWindows) { $gatilhos += New-ScheduledTaskTrigger -AtLogOn -User $usuario }

    $parametros = @{ TaskName = $tarefa; Action = $acao; Principal = $principal; Settings = $config; Force = $true
        Description = 'Abre o widget Monitor de Hardware como administrador (para ler a temperatura da CPU).' }
    if ($gatilhos) { $parametros.Trigger = $gatilhos }
    Register-ScheduledTask @parametros | Out-Null
    Write-Host "Tarefa agendada '$tarefa' criada$(if ($IniciarComWindows) { ' (abre ao entrar no Windows)' })."

    # O atalho so dispara a tarefa, entao abre como admin sem a tela do UAC
    $sh = New-Object -ComObject WScript.Shell
    $lnk = $sh.CreateShortcut($atalho)
    $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\schtasks.exe'
    $lnk.Arguments = "/run /tn `"$tarefa`""
    $lnk.WindowStyle = 7   # minimizado, pra nao piscar o console
    $lnk.IconLocation = (Join-Path $env:SystemRoot 'System32\Taskmgr.exe') + ',0'
    $lnk.Description = 'Monitor de Hardware'
    $lnk.Save()
    Write-Host "Atalho criado no Menu Iniciar: $atalho"
}

function Uninstall-Tarefa {
    if (Get-ScheduledTask -TaskName $tarefa -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $tarefa -Confirm:$false
        Write-Host "Tarefa '$tarefa' removida."
    }
    if (Test-Path $atalho) { Remove-Item $atalho; Write-Host 'Atalho removido.' }
}

function Test-PawnIO {
    # O LibreHardwareMonitor 0.9.5+ usa o driver PawnIO para ler os sensores da CPU
    if (-not (Get-Service PawnIO -ErrorAction SilentlyContinue)) {
        Write-Warning ('O driver PawnIO nao esta instalado, sem ele a temperatura da CPU nao aparece. ' +
            'Instale com:  winget install namazso.PawnIO')
    }
}

try {
    if (-not $Elevado -and -not $Desinstalar) {
        Install-Biblioteca
        Test-PawnIO
        if ($SoBaixar) { return }
    }

    # Tarefa agendada com privilegio maximo precisa de admin: reabre o script elevado so pra essa parte
    if (-not (Test-Admin)) {
        Write-Host 'Pedindo permissao de administrador para criar a tarefa agendada...'
        $argumentos = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Elevado')
        if ($IniciarComWindows) { $argumentos += '-IniciarComWindows' }
        if ($Desinstalar) { $argumentos += '-Desinstalar' }
        $p = Start-Process powershell.exe -Verb RunAs -ArgumentList $argumentos -Wait -PassThru
        if ($p.ExitCode -eq 0) { Write-Host 'Pronto! Abra pelo Menu Iniciar: "Monitor de Hardware".' }
        exit $p.ExitCode
    }

    if ($Desinstalar) { Uninstall-Tarefa } else { Install-Tarefa }
} catch {
    Write-Host "Erro: $($_.Exception.Message)" -ForegroundColor Red
    if ($Elevado) { Read-Host 'Enter para fechar' }
    exit 1
}
if ($Elevado) { Start-Sleep 2 }
