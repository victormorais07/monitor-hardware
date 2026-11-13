# Monitor de hardware na area de trabalho: CPU, GPU, RAM, disco e rede, com historico em mini-graficos.
# Le os sensores com a biblioteca do LibreHardwareMonitor (baixada pelo instalar.ps1 para a pasta lib).
param(
    [switch]$SemAdmin,   # nao pede elevacao (a temperatura da CPU fica indisponivel)
    [string]$Captura     # salva um PNG do widget depois de alguns segundos e fecha (usado no README)
)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$lib = Join-Path $PSScriptRoot 'lib'
$dll = Join-Path $lib 'LibreHardwareMonitorLib.dll'
$configPath = Join-Path $env:APPDATA 'monitor-hardware.json'
$ptBR = [Globalization.CultureInfo]'pt-BR'
$grau = [char]0x00B0
$setaBaixo = [char]0x2193
$setaCima = [char]0x2191

function Show-Erro([string]$msg) {
    [void][Windows.MessageBox]::Show($msg, 'Monitor de Hardware', 'OK', 'Error')
}

if (-not (Test-Path $dll)) {
    Show-Erro "Biblioteca do LibreHardwareMonitor nao encontrada em:`n$lib`n`nRode o instalar.ps1 primeiro."
    exit 1
}

# A temperatura da CPU so pode ser lida como administrador
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin -and -not $SemAdmin -and -not $Captura) {
    try {
        Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ErrorAction Stop -ArgumentList (
            "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`"")
        exit
    } catch {}  # UAC recusado: segue sem admin
}

# Uma instancia so
$mutex = New-Object Threading.Mutex($false, 'Local\MonitorHardwareWidget')
try { if (-not $mutex.WaitOne(0)) { exit } } catch [Threading.AbandonedMutexException] {}

try {
    Add-Type -Path $dll
    $pc = New-Object LibreHardwareMonitor.Hardware.Computer -Property @{
        IsCpuEnabled = $true; IsGpuEnabled = $true; IsMemoryEnabled = $true
        IsStorageEnabled = $true; IsNetworkEnabled = $true
    }
    $pc.Open()
} catch {
    Show-Erro "Nao consegui abrir os sensores:`n$($_.Exception.Message)"
    exit 1
}

# --- Hardware que vai aparecer ---

$hw = @($pc.Hardware)
$cpu = $hw | Where-Object { $_.HardwareType -eq 'Cpu' } | Select-Object -First 1
# Placa de video dedicada tem prioridade sobre a integrada
$gpu = $hw | Where-Object { $_.HardwareType -in 'GpuNvidia', 'GpuAmd' } | Select-Object -First 1
if (-not $gpu) { $gpu = $hw | Where-Object { $_.HardwareType -eq 'GpuIntel' } | Select-Object -First 1 }
$mem = $hw | Where-Object { $_.HardwareType -eq 'Memory' -and $_.Name -notmatch 'Virtual' } | Select-Object -First 1
$discos = @($hw | Where-Object { $_.HardwareType -eq 'Storage' })
$redes = @($hw | Where-Object { $_.HardwareType -eq 'Network' })

# Valor de um sensor pelo tipo e pelo primeiro nome da lista que existir (ou $null)
function Get-Valor($hardware, [string]$tipo, [string[]]$nomes) {
    if (-not $hardware) { return $null }
    foreach ($nome in $nomes) {
        foreach ($s in $hardware.Sensors) {
            if ($s.SensorType -eq $tipo -and $s.Name -eq $nome -and $null -ne $s.Value) { return [double]$s.Value }
        }
    }
    return $null
}

function Get-Cor([double]$v, [double]$amarelo, [double]$vermelho) {
    if ($v -lt $amarelo) { '#7CE38B' } elseif ($v -lt $vermelho) { '#F5C451' } else { '#FF6B6B' }
}

function Format-Velocidade([double]$bytes) {
    if ($bytes -ge 1MB) { return ($bytes / 1MB).ToString('0.0', $ptBR) + ' MB/s' }
    if ($bytes -ge 1KB) { return ($bytes / 1KB).ToString('0', $ptBR) + ' KB/s' }
    return ([math]::Round($bytes)).ToString() + ' B/s'
}

function Format-Num([double]$v, [string]$fmt = '0.0') { $v.ToString($fmt, $ptBR) }

# --- Janela ---

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Monitor de Hardware" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" ResizeMode="NoResize" Width="300" SizeToContent="Height" Left="60" Top="60">
  <Window.Resources>
    <Style x:Key="Rotulo" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe UI Semibold"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Foreground" Value="#B3FFFFFF"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="Nome" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Foreground" Value="#73FFFFFF"/>
      <Setter Property="Margin" Value="8,1,0,0"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
    </Style>
    <Style x:Key="Valor" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe UI Semibold"/>
      <Setter Property="FontSize" Value="20"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="HorizontalAlignment" Value="Right"/>
      <Setter Property="Text" Value="--"/>
    </Style>
    <Style x:Key="Detalhe" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="#99FFFFFF"/>
      <Setter Property="HorizontalAlignment" Value="Right"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="Grafico" TargetType="Canvas">
      <Setter Property="Height" Value="30"/>
      <Setter Property="Margin" Value="0,4,14,0"/>
      <Setter Property="ClipToBounds" Value="True"/>
      <Setter Property="Background" Value="#0DFFFFFF"/>
    </Style>
    <Style x:Key="Barra" TargetType="ProgressBar">
      <Setter Property="Height" Value="5"/>
      <Setter Property="Margin" Value="0,6,14,0"/>
      <Setter Property="Minimum" Value="0"/>
      <Setter Property="Maximum" Value="100"/>
      <Setter Property="Background" Value="#22FFFFFF"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
  </Window.Resources>

  <Border CornerRadius="16" Padding="18,14,18,16" Background="#D912161F" BorderBrush="#33FFFFFF" BorderThickness="1">
    <StackPanel Grid.IsSharedSizeScope="True">

      <!-- CPU -->
      <Grid Margin="0,0,0,14">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto" SharedSizeGroup="Direita"/></Grid.ColumnDefinitions>
        <Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
        <DockPanel>
          <TextBlock Text="CPU" Style="{StaticResource Rotulo}"/>
          <TextBlock x:Name="CpuNome" Style="{StaticResource Nome}"/>
        </DockPanel>
        <TextBlock x:Name="CpuTemp" Grid.Column="1" Style="{StaticResource Valor}"/>
        <Canvas x:Name="CpuGraf" Grid.Row="1" Style="{StaticResource Grafico}"/>
        <StackPanel Grid.Row="1" Grid.Column="1" HorizontalAlignment="Right">
          <TextBlock x:Name="CpuUso" Style="{StaticResource Detalhe}" FontSize="15" Foreground="White" Text="--"/>
          <TextBlock x:Name="CpuPot" Style="{StaticResource Detalhe}"/>
        </StackPanel>
      </Grid>

      <!-- GPU -->
      <Grid x:Name="GpuArea" Margin="0,0,0,14">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto" SharedSizeGroup="Direita"/></Grid.ColumnDefinitions>
        <Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
        <DockPanel>
          <TextBlock Text="GPU" Style="{StaticResource Rotulo}"/>
          <TextBlock x:Name="GpuNome" Style="{StaticResource Nome}"/>
        </DockPanel>
        <TextBlock x:Name="GpuTemp" Grid.Column="1" Style="{StaticResource Valor}"/>
        <Canvas x:Name="GpuGraf" Grid.Row="1" Style="{StaticResource Grafico}"/>
        <StackPanel Grid.Row="1" Grid.Column="1" HorizontalAlignment="Right">
          <TextBlock x:Name="GpuUso" Style="{StaticResource Detalhe}" FontSize="15" Foreground="White" Text="--"/>
          <TextBlock x:Name="GpuVram" Style="{StaticResource Detalhe}"/>
        </StackPanel>
      </Grid>

      <!-- RAM -->
      <Grid Margin="0,0,0,14">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto" SharedSizeGroup="Direita"/></Grid.ColumnDefinitions>
        <Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
        <TextBlock Text="RAM" Style="{StaticResource Rotulo}"/>
        <TextBlock x:Name="RamPct" Grid.Column="1" Style="{StaticResource Valor}"/>
        <ProgressBar x:Name="RamBarra" Grid.Row="1" Style="{StaticResource Barra}"/>
        <TextBlock x:Name="RamDet" Grid.Row="1" Grid.Column="1" Style="{StaticResource Detalhe}"/>
      </Grid>

      <!-- Disco do sistema -->
      <Grid Margin="0,0,0,14">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto" SharedSizeGroup="Direita"/></Grid.ColumnDefinitions>
        <Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
        <DockPanel>
          <TextBlock x:Name="DiscoRotulo" Text="DISCO" Style="{StaticResource Rotulo}"/>
          <TextBlock x:Name="DiscoTemp" Style="{StaticResource Nome}"/>
        </DockPanel>
        <TextBlock x:Name="DiscoPct" Grid.Column="1" Style="{StaticResource Valor}"/>
        <ProgressBar x:Name="DiscoBarra" Grid.Row="1" Style="{StaticResource Barra}"/>
        <TextBlock x:Name="DiscoDet" Grid.Row="1" Grid.Column="1" Style="{StaticResource Detalhe}"/>
      </Grid>

      <!-- Rede -->
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto" SharedSizeGroup="Direita"/></Grid.ColumnDefinitions>
        <Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
        <DockPanel>
          <TextBlock Text="REDE" Style="{StaticResource Rotulo}"/>
          <TextBlock x:Name="RedeNome" Style="{StaticResource Nome}"/>
        </DockPanel>
        <TextBlock x:Name="RedeDown" Grid.Column="1" Style="{StaticResource Valor}" FontSize="16" Foreground="#6CB6FF"/>
        <Canvas x:Name="RedeGraf" Grid.Row="1" Style="{StaticResource Grafico}"/>
        <TextBlock x:Name="RedeUp" Grid.Row="1" Grid.Column="1" Style="{StaticResource Detalhe}" Foreground="#D29BFF"/>
      </Grid>

    </StackPanel>
  </Border>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($n in $xaml.SelectNodes('//*[@*[local-name()="Name"]]')) {
    $nome = $n.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
    $ui[$nome] = $window.FindName($nome)
}

# --- Mini-graficos (historico dos ultimos 60 pontos) ---

$pontos = 60
function New-Grafico($canvas, [string]$cor) {
    $pincel = [Windows.Media.BrushConverter]::new().ConvertFromString($cor)
    $preench = $pincel.Clone(); $preench.Opacity = 0.18
    $area = New-Object Windows.Shapes.Polygon -Property @{ Fill = $preench }
    $linha = New-Object Windows.Shapes.Polyline -Property @{ Stroke = $pincel; StrokeThickness = 1.5; StrokeLineJoin = 'Round' }
    [void]$canvas.Children.Add($area)
    [void]$canvas.Children.Add($linha)
    [pscustomobject]@{ Canvas = $canvas; Area = $area; Linha = $linha; Dados = New-Object Collections.Generic.List[double] }
}

# Adiciona um valor e redesenha. $max = escala fixa (ex.: 100 para %) ou 0 para escala automatica.
function Add-Ponto($g, [double]$valor, [double]$max) {
    $g.Dados.Add($valor)
    if ($g.Dados.Count -gt $pontos) { $g.Dados.RemoveAt(0) }
    $w = $g.Canvas.ActualWidth; $h = $g.Canvas.ActualHeight
    if ($w -le 0 -or $h -le 0) { return }
    if ($max -le 0) { $max = [math]::Max(($g.Dados | Measure-Object -Maximum).Maximum, 1) }
    $passo = $w / ($pontos - 1)
    $x0 = $w - ($g.Dados.Count - 1) * $passo
    $linha = New-Object Windows.Media.PointCollection
    for ($i = 0; $i -lt $g.Dados.Count; $i++) {
        $y = $h - 1 - [math]::Min($g.Dados[$i] / $max, 1) * ($h - 3)
        $linha.Add((New-Object Windows.Point ($x0 + $i * $passo), $y))
    }
    $area = $linha.Clone()
    $area.Add((New-Object Windows.Point $w, $h))
    $area.Add((New-Object Windows.Point $x0, $h))
    $g.Linha.Points = $linha
    $g.Area.Points = $area
}

$grafCpu = New-Grafico $ui.CpuGraf '#7CE38B'
$grafGpu = New-Grafico $ui.GpuGraf '#F5A851'
$grafDown = New-Grafico $ui.RedeGraf '#6CB6FF'
$grafUp = New-Grafico $ui.RedeGraf '#D29BFF'

# --- Textos fixos ---

if ($cpu) { $ui.CpuNome.Text = $cpu.Name -replace '^(Intel|AMD)\s+', '' }
if ($gpu) { $ui.GpuNome.Text = $gpu.Name -replace '^(NVIDIA|AMD|Intel\(R\))\s+', '' }
else { $ui.GpuArea.Visibility = 'Collapsed' }

$ui.DiscoRotulo.Text = 'DISCO ' + $env:SystemDrive

if (-not $admin) {
    $ui.CpuTemp.ToolTip = 'A temperatura da CPU so aparece rodando como administrador'
}

# --- Atualizacao ---

$tick = 0
function Update-Cpu {
    if (-not $cpu) { return }
    $cpu.Update()
    $t = Get-Valor $cpu 'Temperature' 'CPU Package', 'Core (Tctl/Tdie)', 'Core Max', 'Core Average'
    if ($null -ne $t) { $ui.CpuTemp.Text = "{0:0}$grau" -f $t; $ui.CpuTemp.Foreground = Get-Cor $t 60 80 }
    else { $ui.CpuTemp.Text = "--$grau"; $ui.CpuTemp.Foreground = 'White' }
    $uso = Get-Valor $cpu 'Load' 'CPU Total'
    if ($null -ne $uso) { $ui.CpuUso.Text = "{0:0}%" -f $uso; Add-Ponto $grafCpu $uso 100 }
    $w = Get-Valor $cpu 'Power' 'CPU Package'
    $ui.CpuPot.Text = if ($w -gt 0) { (Format-Num $w '0') + ' W' } else { '' }
}

function Update-Gpu {
    if (-not $gpu) { return }
    $gpu.Update()
    $t = Get-Valor $gpu 'Temperature' 'GPU Core'
    if ($null -ne $t) { $ui.GpuTemp.Text = "{0:0}$grau" -f $t; $ui.GpuTemp.Foreground = Get-Cor $t 65 80 }
    $uso = Get-Valor $gpu 'Load' 'GPU Core', 'D3D 3D'
    if ($null -ne $uso) { $ui.GpuUso.Text = "{0:0}%" -f $uso; Add-Ponto $grafGpu $uso 100 }
    $usada = Get-Valor $gpu 'SmallData' 'GPU Memory Used', 'D3D Dedicated Memory Used'
    $total = Get-Valor $gpu 'SmallData' 'GPU Memory Total'
    if ($null -ne $usada -and $total -gt 0) {
        $ui.GpuVram.Text = 'VRAM {0} / {1} GB' -f (Format-Num ($usada / 1024)), (Format-Num ($total / 1024) '0')
    }
}

function Update-Ram {
    if (-not $mem) { return }
    $mem.Update()
    $pct = Get-Valor $mem 'Load' 'Memory'
    $usada = Get-Valor $mem 'Data' 'Memory Used'
    $livre = Get-Valor $mem 'Data' 'Memory Available'
    if ($null -eq $pct) { return }
    $cor = Get-Cor $pct 70 85
    $ui.RamPct.Text = "{0:0}%" -f $pct
    $ui.RamPct.Foreground = $cor
    $ui.RamBarra.Value = $pct
    $ui.RamBarra.Foreground = $cor
    if ($null -ne $usada -and $null -ne $livre) {
        $ui.RamDet.Text = '{0} / {1} GB' -f (Format-Num $usada), (Format-Num ($usada + $livre) '0')
    }
}

function Update-Disco {
    try {
        $discoSistema = New-Object IO.DriveInfo ($env:SystemDrive)   # DriveInfo nao atualiza sozinho
        $total = $discoSistema.TotalSize; $livre = $discoSistema.AvailableFreeSpace
        $pct = ($total - $livre) / $total * 100
        $cor = Get-Cor $pct 80 92
        $ui.DiscoPct.Text = "{0:0}%" -f $pct
        $ui.DiscoPct.Foreground = $cor
        $ui.DiscoBarra.Value = $pct
        $ui.DiscoBarra.Foreground = $cor
        $ui.DiscoDet.Text = '{0} GB livres' -f (Format-Num ($livre / 1GB) '0')
    } catch {}
    # Temperatura dos discos (SMART). Mostra a mais alta e lista todas no tooltip.
    $temps = foreach ($d in $discos) {
        $d.Update()
        $t = Get-Valor $d 'Temperature' 'Temperature', 'Composite Temperature'
        if ($null -ne $t) { [pscustomobject]@{ Nome = $d.Name; Temp = $t } }
    }
    if ($temps) {
        $maior = $temps | Sort-Object Temp -Descending | Select-Object -First 1
        $ui.DiscoTemp.Text = "{0:0}$grau" -f $maior.Temp
        $ui.DiscoTemp.ToolTip = ($temps | ForEach-Object { "{0}: {1:0}$grau" -f $_.Nome, $_.Temp }) -join "`n"
    }
}

function Update-Rede {
    if (-not $redes) { return }
    foreach ($r in $redes) { $r.Update() }
    # A placa principal e a que mais trafegou desde que o PC ligou
    # (somar todas contaria duas vezes o trafego de VPN, que tambem passa pela placa fisica)
    $principal = $redes | Sort-Object { [double](Get-Valor $_ 'Data' 'Data Downloaded') + [double](Get-Valor $_ 'Data' 'Data Uploaded') } -Descending |
        Select-Object -First 1
    $down = [double](Get-Valor $principal 'Throughput' 'Download Speed')
    $up = [double](Get-Valor $principal 'Throughput' 'Upload Speed')
    $ui.RedeNome.Text = $principal.Name
    $ui.RedeDown.Text = "$setaBaixo " + (Format-Velocidade $down)
    $ui.RedeUp.Text = "$setaCima " + (Format-Velocidade $up)
    # Download e upload na mesma escala, para dar pra comparar
    $max = [math]::Max(1KB, (@($grafDown.Dados) + @($grafUp.Dados) + $down + $up | Measure-Object -Maximum).Maximum)
    Add-Ponto $grafDown $down $max
    Add-Ponto $grafUp $up $max
}

function Update-Tudo {
    foreach ($f in 'Update-Cpu', 'Update-Gpu', 'Update-Ram', 'Update-Rede') {
        try { & $f } catch {}
    }
    # SMART dos discos e mais lento; atualiza a cada 10 s
    if ($script:tick % 10 -eq 0) { try { Update-Disco } catch {} }
    $script:tick++
}

# --- Posicao, menu e arrastar ---

if (Test-Path $configPath) {
    try {
        $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
        # So restaura se a posicao ainda estiver dentro da area dos monitores
        $vs = [Windows.SystemParameters]
        if ($cfg.Left -ge $vs::VirtualScreenLeft -and $cfg.Left -lt $vs::VirtualScreenLeft + $vs::VirtualScreenWidth - 50 -and
            $cfg.Top -ge $vs::VirtualScreenTop -and $cfg.Top -lt $vs::VirtualScreenTop + $vs::VirtualScreenHeight - 50) {
            $window.Left = $cfg.Left
            $window.Top = $cfg.Top
        }
        $window.Topmost = [bool]$cfg.Topmost
    } catch {}
}

function Save-Config {
    @{ Left = $window.Left; Top = $window.Top; Topmost = $window.Topmost } |
        ConvertTo-Json | Set-Content $configPath -Encoding utf8
}

$window.Add_MouseLeftButtonDown({ try { $window.DragMove(); Save-Config } catch {} })

$menu = New-Object Windows.Controls.ContextMenu
$itemTopo = New-Object Windows.Controls.MenuItem -Property @{ Header = 'Sempre no topo'; IsCheckable = $true; IsChecked = $window.Topmost }
$itemTopo.Add_Click({ $window.Topmost = $itemTopo.IsChecked; Save-Config })
$itemFechar = New-Object Windows.Controls.MenuItem -Property @{ Header = 'Fechar' }
$itemFechar.Add_Click({ $window.Close() })
[void]$menu.Items.Add($itemTopo)
[void]$menu.Items.Add((New-Object Windows.Controls.Separator))
[void]$menu.Items.Add($itemFechar)
$window.ContextMenu = $menu

# --- Captura para o README ---

function Save-Captura([string]$arquivo) {
    $el = $window.Content
    $escala = 2
    $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap ([int]($el.ActualWidth * $escala)), ([int]($el.ActualHeight * $escala)),
        (96 * $escala), (96 * $escala), ([Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($el)
    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $fs = [IO.File]::Create($arquivo)
    try { $enc.Save($fs) } finally { $fs.Close() }
}

# --- Loop ---

$timer = New-Object Windows.Threading.DispatcherTimer -Property @{ Interval = [TimeSpan]::FromSeconds(1) }
$timer.Add_Tick({
    Update-Tudo
    if ($Captura -and $script:tick -ge 45) {
        Save-Captura ([IO.Path]::GetFullPath($Captura))
        $window.Close()
    }
})
$window.Add_ContentRendered({ Update-Tudo; $timer.Start() })
$window.Add_Closed({
    $timer.Stop()
    try { $pc.Close() } catch {}
    try { $mutex.ReleaseMutex() } catch {}
})

[void]$window.ShowDialog()
