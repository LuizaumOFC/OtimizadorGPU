# ==========================================================================
#  Otimizador GPU & Windows  -  diagnostico da placa de video + otimizador
#  Roda em Windows 10 e 11 com o PowerShell que ja vem no sistema.
#  Nada e instalado e nada e baixado. Todos os ajustes tem "Desfazer".
# ==========================================================================
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# ---------- Qualquer erro ao iniciar aparece numa janela e vai para erro.txt ----------
$LogEarly = Join-Path $env:ProgramData 'OtimizadorGPU'
trap {
    try {
        if (-not (Test-Path $LogEarly)) { New-Item -ItemType Directory -Path $LogEarly -Force | Out-Null }
        Add-Content -Path (Join-Path $LogEarly 'erro.txt') -Value ("[{0}] {1}`r`n{2}" -f (Get-Date), $_.Exception.Message, $_.ScriptStackTrace)
    } catch {}
    [System.Windows.MessageBox]::Show("Erro ao iniciar:`n`n$($_.Exception.Message)`n`nLinha: $($_.InvocationInfo.ScriptLineNumber)", 'Otimizador GPU', 'OK', 'Error') | Out-Null
    exit 1
}


# ---------- Precisa de administrador e de modo STA (janela WPF) ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$isSta = [Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA'
if (-not $isAdmin -or -not $isSta) {
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"")
    } catch {
        [System.Windows.MessageBox]::Show('Este programa precisa ser aberto como Administrador para aplicar os ajustes.', 'Otimizador GPU', 'OK', 'Warning') | Out-Null
    }
    exit
}

# ---------- Pastas de apoio (log e arquivo de desfazer) ----------
$AppDir = Join-Path $env:ProgramData 'OtimizadorGPU'
if (-not (Test-Path $AppDir)) { New-Item -ItemType Directory -Path $AppDir -Force | Out-Null }
$UndoFile = Join-Path $AppDir 'desfazer.json'
$LogFile = Join-Path $AppDir 'log.txt'
$script:LogBox = $null
$script:Vendor = 'Desconhecido'
$script:Gpus = @()
$script:RestoreDone = $false
$script:Scanned = $false

function Write-Log($msg) {
    $line = '[{0:HH:mm:ss}] {1}' -f (Get-Date), $msg
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch {}
    if ($script:LogBox) { $script:LogBox.AppendText($line + "`r`n"); $script:LogBox.ScrollToEnd() }
}

function DoEvents {
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Background,
        [System.Windows.Threading.DispatcherOperationCallback]{ param($f) $f.Continue = $false; return $null },
        $frame) | Out-Null
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

function Brush($hex) { [Windows.Media.BrushConverter]::new().ConvertFromString($hex) }

# ---------- Sistema: Windows 10 ou 11 ----------
$osInfo = Get-CimInstance Win32_OperatingSystem
if ([version]$osInfo.Version -lt [version]'10.0') {
    [System.Windows.MessageBox]::Show('Este programa funciona apenas no Windows 10 e no Windows 11.', 'Otimizador GPU', 'OK', 'Warning') | Out-Null
    exit
}
$Build = [int]$osInfo.BuildNumber
$IsWin11 = $Build -ge 22000
$WinVer = ''
try { $WinVer = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').DisplayVersion } catch {}
$WinName = ($osInfo.Caption -replace '^Microsoft\s+', '').Trim()
$IsLaptop = $false
try { $IsLaptop = [bool](Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue) } catch {}

# ---------- Registro e desfazer ----------
function Set-Reg($path, $name, $value, $type = 'DWord') {
    if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
    New-ItemProperty -Path $path -Name $name -Value $value -PropertyType $type -Force | Out-Null
}
function New-RegOp($p, $n, $v, $t = 'DWord') { [pscustomobject]@{ P = $p; N = $n; V = $v; T = $t } }

function Load-Undo {
    if (Test-Path $UndoFile) {
        try { return @(Get-Content -Path $UndoFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return @() }
    }
    return @()
}
$script:Undo = @(Load-Undo)
function Save-Undo { ConvertTo-Json -InputObject @($script:Undo) -Depth 5 | Set-Content -Path $UndoFile -Encoding UTF8 }

function Add-UndoReg($id, $path, $name, $type) {
    foreach ($u in @($script:Undo)) { if ($u.Kind -eq 'reg' -and $u.Path -eq $path -and $u.Name -eq $name) { return } }
    $existed = $false; $old = $null
    try { $p = Get-ItemProperty -Path $path -Name $name -ErrorAction Stop; $old = $p.$name; $existed = $true } catch {}
    $script:Undo += [pscustomobject]@{ Tweak = $id; Kind = 'reg'; Path = $path; Name = $name; Existed = $existed; Old = $old; Type = $type }
    Save-Undo
}
function Add-UndoOther($id, $kind, $old) {
    $script:Undo += [pscustomobject]@{ Tweak = $id; Kind = $kind; Path = ''; Name = ''; Existed = $true; Old = $old; Type = '' }
    Save-Undo
}

function Invoke-UndoAll {
    $items = @($script:Undo)
    [array]::Reverse($items)
    foreach ($u in $items) {
        try {
            switch ($u.Kind) {
                'reg' {
                    if ($u.Existed) { Set-Reg $u.Path $u.Name $u.Old $u.Type }
                    else { Remove-ItemProperty -Path $u.Path -Name $u.Name -ErrorAction SilentlyContinue }
                }
                'power' { & powercfg /setactive $u.Old 2>&1 | Out-Null }
                'hib' { if ([int]$u.Old -eq 1) { & powercfg -h on 2>&1 | Out-Null } }
            }
        } catch { Write-Log "  nao foi possivel reverter $($u.Name): $($_.Exception.Message)" }
    }
    $script:Undo = @()
    Save-Undo
}

function Clear-Folder($paths) {
    $freed = [int64]0
    foreach ($p in $paths) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        foreach ($item in @(Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue)) {
            try {
                $size = 0
                if ($item.PSIsContainer) {
                    $size = (Get-ChildItem -LiteralPath $item.FullName -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
                } else { $size = $item.Length }
                Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
                $freed += [int64]$size
            } catch {}
        }
    }
    return $freed
}

function New-RestorePoint {
    try {
        Write-Log 'Criando ponto de restauracao do Windows...'
        Enable-ComputerRestore -Drive "$($env:SystemDrive)\" -ErrorAction SilentlyContinue
        $wv = $null
        Checkpoint-Computer -Description 'Otimizador GPU e Windows' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop -WarningVariable wv -WarningAction SilentlyContinue
        if ($wv) { Write-Log 'O Windows permite 1 ponto a cada 24h; ja existe um recente, seguindo em frente.' }
        else { Write-Log 'Ponto de restauracao criado.' }
        return $true
    } catch {
        Write-Log "Nao foi possivel criar o ponto de restauracao: $($_.Exception.Message)"
        return $false
    }
}

# ---------- Lista de ajustes ----------
$ShaderPaths = @("$env:LOCALAPPDATA\D3DSCache", "$env:LOCALAPPDATA\AMD\DxCache", "$env:LOCALAPPDATA\AMD\GLCache", "$env:LOCALAPPDATA\NVIDIA\DXCache", "$env:LOCALAPPDATA\NVIDIA\GLCache")
$MmPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
$CdmPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'

$Tweaks = @(
    # ---------------- GPU ----------------
    @{ Id = 'gamemode'; Group = 'GPU'; OS = 'All'; Default = $true
        Name = 'Modo de Jogo do Windows'
        Desc = 'Prioriza o jogo em primeiro plano e evita que o Windows use a GPU e o processador em tarefas pesadas durante a partida.'
        Reg = @((New-RegOp 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1), (New-RegOp 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1)) },
    @{ Id = 'gamedvr'; Group = 'GPU'; OS = 'All'; Default = $true
        Name = 'Desativar gravacao em segundo plano (Game DVR)'
        Desc = 'A captura automatica de video do Xbox Game Bar consome GPU e pode causar quedas de FPS. Voce ainda pode gravar com o software da placa.'
        Reg = @((New-RegOp 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0), (New-RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0), (New-RegOp 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0)) },
    @{ Id = 'power'; Group = 'GPU'; OS = 'All'; Default = (-not $IsLaptop)
        Name = 'Plano de energia de desempenho maximo'
        Desc = 'Impede que o processador e a placa reduzam a velocidade para economizar energia. Em notebook aumenta o consumo da bateria.'
        Apply = {
            $guidRx = '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}'
            $cur = (& powercfg /getactivescheme) -join ' '
            $m = [regex]::Match($cur, $guidRx)
            $old = $null
            if ($m.Success) { $old = $m.Value }
            $new = $null
            $list = @(& powercfg /list)
            $line = $list | Where-Object { $_ -match 'Ultimate|Desempenho m[aáà]ximo|M[aáà]ximo desempenho' } | Select-Object -First 1
            if ($line) { $mm = [regex]::Match($line, $guidRx); if ($mm.Success) { $new = $mm.Value } }
            if (-not $new) {
                $out = (& powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 2>&1) -join ' '
                $mm = [regex]::Match($out, $guidRx)
                if ($mm.Success) { $new = $mm.Value }
            }
            if (-not $new) {
                $line = $list | Where-Object { $_ -match 'High performance|Alto desempenho' } | Select-Object -First 1
                if ($line) { $mm = [regex]::Match($line, $guidRx); if ($mm.Success) { $new = $mm.Value } }
            }
            if (-not $new) { throw 'Este PC nao oferece um plano de desempenho maximo.' }
            if ($old -and $old -ne $new) { Add-UndoOther 'power' 'power' $old }
            & powercfg /setactive $new 2>&1 | Out-Null
            return 'Plano de desempenho ativado.'
        } },
    @{ Id = 'mmcss'; Group = 'GPU'; OS = 'All'; Default = $true
        Name = 'Prioridade de jogos no agendador multimidia'
        Desc = 'Da mais prioridade de CPU e GPU para jogos e reduz o limite de rede do Windows. Ganho pequeno, mas ajuda a deixar o tempo de quadro mais estavel.'
        Reg = @(
            (New-RegOp $MmPath 'SystemResponsiveness' 10),
            (New-RegOp $MmPath 'NetworkThrottlingIndex' 0xffffffff),
            (New-RegOp "$MmPath\Tasks\Games" 'GPU Priority' 8),
            (New-RegOp "$MmPath\Tasks\Games" 'Priority' 6),
            (New-RegOp "$MmPath\Tasks\Games" 'Scheduling Category' 'High' 'String'),
            (New-RegOp "$MmPath\Tasks\Games" 'SFIO Priority' 'High' 'String')) },
    @{ Id = 'hags'; Group = 'GPU'; OS = 'All'; Default = $false; Reboot = $true
        Name = 'Agendamento de GPU acelerado por hardware (opcional)'
        Desc = 'A placa passa a gerenciar sua propria memoria de video. Costuma ajudar em placas recentes (RX 5000+, GTX 1000+), mas em alguns PCs causa engasgos. Requer reiniciar.'
        Reg = @((New-RegOp 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2)) },
    @{ Id = 'shader'; Group = 'GPU'; OS = 'All'; Default = $false
        Name = 'Limpar cache de shaders (use se tiver travadinhas)'
        Desc = 'Apaga o cache de shaders da DirectX, AMD e NVIDIA. Corrige engasgos depois de trocar de driver. Os jogos recriam o cache e podem demorar um pouco mais na primeira abertura.'
        Apply = {
            $b = Clear-Folder $ShaderPaths
            return ('Cache limpo (' + [math]::Round($b / 1MB, 1) + ' MB liberados).')
        } },
    # ---------------- Windows ----------------
    @{ Id = 'transparency'; Group = 'WIN'; OS = 'All'; Default = $true
        Name = 'Desativar efeitos de transparencia'
        Desc = 'Menos trabalho para a placa de video na interface do Windows. Libera um pouco de GPU e memoria.'
        Reg = @((New-RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0)) },
    @{ Id = 'animations'; Group = 'WIN'; OS = 'All'; Default = $true
        Name = 'Desativar animacoes de janelas e da barra de tarefas'
        Desc = 'O Windows responde de forma mais rapida. Aparece por completo depois de sair e entrar na conta.'
        Reg = @((New-RegOp 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' 'String'), (New-RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 0)) },
    @{ Id = 'bgapps'; Group = 'WIN'; OS = 'All'; Default = $true
        Name = 'Bloquear aplicativos em segundo plano'
        Desc = 'Impede que apps da Microsoft Store fiquem rodando escondidos gastando memoria e processador.'
        Reg = @((New-RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1), (New-RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BackgroundAppGlobalToggle' 0)) },
    @{ Id = 'tips'; Group = 'WIN'; OS = 'All'; Default = $true
        Name = 'Desativar sugestoes, dicas e anuncios do Windows'
        Desc = 'Remove sugestoes de apps no menu Iniciar, dicas na tela de bloqueio e notificacoes de propaganda.'
        Reg = @(
            (New-RegOp $CdmPath 'SubscribedContent-338388Enabled' 0), (New-RegOp $CdmPath 'SubscribedContent-338389Enabled' 0),
            (New-RegOp $CdmPath 'SubscribedContent-310093Enabled' 0), (New-RegOp $CdmPath 'SubscribedContent-353698Enabled' 0),
            (New-RegOp $CdmPath 'SystemPaneSuggestionsEnabled' 0), (New-RegOp $CdmPath 'SoftLandingEnabled' 0)) },
    @{ Id = 'startupdelay'; Group = 'WIN'; OS = 'All'; Default = $true
        Name = 'Iniciar programas sem atraso artificial'
        Desc = 'O Windows espera alguns segundos antes de abrir os programas de inicializacao. Isso tira a espera.'
        Reg = @((New-RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec' 0)) },
    @{ Id = 'widgets11'; Group = 'WIN'; OS = '11'; Default = $true
        Name = 'Desativar Widgets (Windows 11)'
        Desc = 'O painel de Widgets roda varios processos em segundo plano. Desativando, voce economiza memoria.'
        Reg = @((New-RegOp 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0)) },
    @{ Id = 'feeds10'; Group = 'WIN'; OS = '10'; Default = $true
        Name = 'Desativar Noticias e interesses (Windows 10)'
        Desc = 'Remove o widget de noticias e clima da barra de tarefas, que fica atualizando o tempo todo.'
        Reg = @((New-RegOp 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds' 'EnableFeeds' 0)) },
    @{ Id = 'mouseaccel'; Group = 'WIN'; OS = 'All'; Default = $false
        Name = 'Desativar aceleracao do mouse (opcional)'
        Desc = 'O ponteiro passa a andar sempre a mesma distancia para o mesmo movimento. Preferido em jogos de tiro. Vale apos sair e entrar na conta.'
        Reg = @((New-RegOp 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0' 'String'), (New-RegOp 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '0' 'String'), (New-RegOp 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '0' 'String')) },
    @{ Id = 'telemetry'; Group = 'WIN'; OS = 'All'; Default = $false
        Name = 'Reduzir telemetria do Windows (opcional)'
        Desc = 'Diminui o envio de dados de uso para a Microsoft. No Windows Home e Pro o sistema mantem o nivel minimo permitido, nao zera tudo.'
        Reg = @((New-RegOp 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0), (New-RegOp 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'DoNotShowFeedbackNotifications' 1)) },
    @{ Id = 'hibernate'; Group = 'WIN'; OS = 'All'; Default = $false
        Name = 'Desativar hibernacao e inicializacao rapida (opcional)'
        Desc = 'Libera varios GB no disco (arquivo hiberfil.sys) e evita problemas de driver apos desligar. Voce perde a opcao Hibernar.'
        Apply = {
            $en = 1
            try { $en = [int](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name HibernateEnabled -ErrorAction Stop).HibernateEnabled } catch {}
            Add-UndoOther 'hibernate' 'hib' $en
            & powercfg -h off 2>&1 | Out-Null
            return 'Hibernacao desativada.'
        } },
    @{ Id = 'tempclean'; Group = 'WIN'; OS = 'All'; Default = $true
        Name = 'Limpar arquivos temporarios'
        Desc = 'Apaga o lixo das pastas Temp do usuario e do Windows. Arquivos em uso sao ignorados. Esta acao nao tem desfazer.'
        Apply = {
            $b = Clear-Folder @($env:TEMP, "$($env:SystemRoot)\Temp")
            return ('Temporarios limpos (' + [math]::Round($b / 1MB, 1) + ' MB liberados).')
        } }
)

function Invoke-Tweak($t) {
    if ($t.Reg) {
        $ok = 0; $fail = 0
        foreach ($r in $t.Reg) {
            try { Add-UndoReg $t.Id $r.P $r.N $r.T; Set-Reg $r.P $r.N $r.V $r.T; $ok++ }
            catch { $fail++; Write-Log "  falhou em $($r.N): $($_.Exception.Message)" }
        }
        if ($ok -eq 0) { throw 'O Windows nao permitiu este ajuste.' }
        return "$ok de $($ok + $fail) alteracoes aplicadas"
    }
    if ($t.Apply) { return [string](@(& $t.Apply) | Select-Object -Last 1) }
}

# ---------- Deteccao da GPU ----------
function Get-VramGB($gpu) {
    try {
        $base = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
        foreach ($k in @(Get-ChildItem $base -ErrorAction SilentlyContinue)) {
            if ($k.PSChildName -notmatch '^\d{4}$') { continue }
            $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
            if ($p.DriverDesc -eq $gpu.Name -and $null -ne $p.'HardwareInformation.qwMemorySize') {
                $v = $p.'HardwareInformation.qwMemorySize'
                if ($v -is [byte[]]) { $v = [BitConverter]::ToUInt64($v, 0) }
                return [math]::Round(([double]$v) / 1GB, 1)
            }
        }
    } catch {}
    if ($gpu.AdapterRAM -and $gpu.AdapterRAM -gt 0) { return [math]::Round($gpu.AdapterRAM / 1GB, 1) }
    return $null
}

function Get-Gpus {
    $list = @(Get-CimInstance Win32_VideoController | Where-Object { $_.Name -and $_.Name -notmatch 'Remote|Virtual|Parsec|Citrix|DisplayLink|Mirage' })
    $out = foreach ($g in $list) {
        $vendor = 'Desconhecido'
        $id = "$($g.AdapterCompatibility) $($g.Name)"
        if ($id -match 'NVIDIA|GeForce') { $vendor = 'NVIDIA' }
        elseif ($id -match 'AMD|Advanced Micro|Radeon|ATI ') { $vendor = 'AMD' }
        elseif ($id -match 'Intel') { $vendor = 'Intel' }
        $dedicated = [bool]($g.Name -match 'GeForce|RTX|GTX|Quadro|Radeon (RX|Pro|R[0-9]|HD)|Radeon\(TM\) (RX|Pro)|\bArc\b')
        [pscustomobject]@{ Obj = $g; Name = $g.Name; Vendor = $vendor; Dedicated = $dedicated; VramGB = (Get-VramGB $g) }
    }
    return @($out)
}

function Get-NvidiaVer($v) {
    $d = ($v -replace '\D', '')
    if ($d.Length -ge 5) { $x = $d.Substring($d.Length - 5); return "$($x.Substring(0,3)).$($x.Substring(3))" }
    return $v
}

# ---------- Interface (XAML) ----------
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Otimizador GPU &amp; Windows" Width="1100" Height="740" MinWidth="920" MinHeight="620"
        WindowStartupLocation="CenterScreen" Background="#0B1220" FontFamily="Segoe UI" FontSize="13" Foreground="#E6EDF7">
  <Window.Resources>
    <Style x:Key="Primary" TargetType="Button">
      <Setter Property="Background" Value="#22D3EE"/>
      <Setter Property="Foreground" Value="#06222B"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="18,10"/>
      <Setter Property="Margin" Value="0,0,10,10"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="bd" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Ghost" TargetType="Button" BasedOn="{StaticResource Primary}">
      <Setter Property="Background" Value="#1B2A47"/>
      <Setter Property="Foreground" Value="#E6EDF7"/>
      <Setter Property="FontWeight" Value="Normal"/>
    </Style>
    <Style x:Key="Nav" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#E6EDF7"/>
      <Setter Property="Padding" Value="14,11"/>
      <Setter Property="Margin" Value="0,0,0,4"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Left" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.8"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="H2" TargetType="TextBlock">
      <Setter Property="FontSize" Value="17"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,26,0,4"/>
    </Style>
  </Window.Resources>
  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="230"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <Border Grid.Column="0" Background="#0F1A2E">
      <DockPanel Margin="18">
        <StackPanel DockPanel.Dock="Top">
          <TextBlock Text="⚡ Otimizador" FontSize="21" FontWeight="Bold" Foreground="#22D3EE"/>
          <TextBlock Text="GPU &amp; Windows" Foreground="#8FA3BF" Margin="0,0,0,26"/>
          <Button x:Name="NavDiag" Style="{StaticResource Nav}" Content="🔍  Diagnóstico da GPU"/>
          <Button x:Name="NavWin" Style="{StaticResource Nav}" Content="🚀  Otimizador Windows"/>
          <Button x:Name="NavGuide" Style="{StaticResource Nav}" Content="🖼  Guia visual Adrenalin"/>
          <Button x:Name="NavTut" Style="{StaticResource Nav}" Content="📘  Tutorial"/>
        </StackPanel>
        <StackPanel DockPanel.Dock="Bottom" VerticalAlignment="Bottom">
          <TextBlock x:Name="SysOS" TextWrapping="Wrap" Foreground="#8FA3BF" FontSize="11" Margin="0,0,0,6"/>
          <TextBlock x:Name="SysGPU" TextWrapping="Wrap" Foreground="#8FA3BF" FontSize="11"/>
        </StackPanel>
        <Grid/>
      </DockPanel>
    </Border>

    <Grid Grid.Column="1">
      <Grid.RowDefinitions>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <Grid Grid.Row="0">
        <!-- ===== Diagnóstico ===== -->
        <ScrollViewer x:Name="PanelDiag" VerticalScrollBarVisibility="Auto" Padding="30,26,30,16">
          <StackPanel>
            <TextBlock Text="Diagnóstico da placa de vídeo" FontSize="24" FontWeight="Bold"/>
            <TextBlock Text="Analisa sua GPU, procura problemas e sugere ajustes seguros." Foreground="#8FA3BF" Margin="0,4,0,18"/>
            <Border Background="#131F36" CornerRadius="12" Padding="18">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="GpuInfo" Text="Detectando a placa de vídeo..." TextWrapping="Wrap" LineHeight="22"/>
                <Button x:Name="BtnScan" Grid.Column="1" Style="{StaticResource Primary}" Content="Analisar agora" VerticalAlignment="Center" Margin="16,0,0,0"/>
              </Grid>
            </Border>

            <TextBlock Text="Resultado da análise" Style="{StaticResource H2}"/>
            <StackPanel x:Name="Findings" Margin="0,8,0,0"/>

            <TextBlock Text="Ajustes recomendados para jogos" Style="{StaticResource H2}"/>
            <TextBlock Text="Marque o que quiser aplicar. Tudo pode ser desfeito na aba Otimizador Windows." Foreground="#8FA3BF" Margin="0,0,0,12"/>
            <StackPanel x:Name="GpuTweaks"/>
            <WrapPanel Margin="0,8,0,0">
              <Button x:Name="BtnApplyGpu" Style="{StaticResource Primary}" Content="Aplicar ajustes marcados"/>
              <Button x:Name="BtnOpenPanel" Style="{StaticResource Ghost}" Content="Abrir painel da placa"/>
              <Button x:Name="BtnDriver" Style="{StaticResource Ghost}" Content="Baixar driver"/>
              <Button x:Name="BtnWinGfx" Style="{StaticResource Ghost}" Content="Gráficos do Windows"/>
            </WrapPanel>

            <TextBlock Text="Configurações do painel da placa" Style="{StaticResource H2}"/>
            <TextBlock Text="O fabricante não permite que outros programas mexam nessas opções, então aqui vai o passo a passo para você marcar em 2 minutos." Foreground="#8FA3BF" TextWrapping="Wrap" Margin="0,0,0,12"/>
            <Border Background="#131F36" CornerRadius="12" Padding="18">
              <TextBlock x:Name="VendorGuide" TextWrapping="Wrap" LineHeight="22"/>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- ===== Otimizador Windows ===== -->
        <ScrollViewer x:Name="PanelWin" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" Padding="30,26,30,16">
          <StackPanel>
            <TextBlock Text="Otimizador Windows" FontSize="24" FontWeight="Bold"/>
            <TextBlock x:Name="OsInfo" Foreground="#8FA3BF" TextWrapping="Wrap" Margin="0,4,0,18"/>
            <Border Background="#131F36" CornerRadius="12" Padding="18">
              <StackPanel>
                <TextBlock Text="Antes de começar" FontWeight="SemiBold" Margin="0,0,0,4"/>
                <TextBlock Text="O programa cria um ponto de restauração automaticamente e guarda os valores originais. Se algo não agradar, use Desfazer tudo." Foreground="#8FA3BF" TextWrapping="Wrap" Margin="0,0,0,12"/>
                <WrapPanel>
                  <Button x:Name="BtnRestore" Style="{StaticResource Ghost}" Content="Criar ponto de restauração" Margin="0,0,10,0"/>
                </WrapPanel>
              </StackPanel>
            </Border>
            <TextBlock Text="Otimizações" Style="{StaticResource H2}"/>
            <StackPanel x:Name="WinTweaks" Margin="0,8,0,0"/>
            <WrapPanel Margin="0,8,0,0">
              <Button x:Name="BtnApplyWin" Style="{StaticResource Primary}" Content="Aplicar selecionadas"/>
              <Button x:Name="BtnRecommended" Style="{StaticResource Ghost}" Content="Marcar recomendadas"/>
              <Button x:Name="BtnUndo" Style="{StaticResource Ghost}" Content="Desfazer tudo"/>
            </WrapPanel>
          </StackPanel>
        </ScrollViewer>

        <!-- ===== Guia visual ===== -->
        <ScrollViewer x:Name="PanelGuide" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" Padding="30,26,30,16">
          <StackPanel>
            <TextBlock Text="Guia visual do Adrenalin" FontSize="24" FontWeight="Bold"/>
            <TextBlock Text="Como deixar as telas Gráficos, Tela e Desempenho &gt; Ajuste, opção por opção." Foreground="#8FA3BF" Margin="0,4,0,18"/>
            <StackPanel x:Name="GuideHost"/>
          </StackPanel>
        </ScrollViewer>

        <!-- ===== Tutorial ===== -->
        <ScrollViewer x:Name="PanelTut" Visibility="Collapsed" VerticalScrollBarVisibility="Auto" Padding="30,26,30,16">
          <StackPanel>
            <TextBlock Text="Tutorial" FontSize="24" FontWeight="Bold"/>
            <TextBlock Text="Leva menos de 5 minutos. Siga a ordem." Foreground="#8FA3BF" Margin="0,4,0,18"/>
            <StackPanel x:Name="TutorialHost"/>
          </StackPanel>
        </ScrollViewer>
      </Grid>

      <Border Grid.Row="1" Background="#0F1A2E" Height="118">
        <TextBox x:Name="LogBox" IsReadOnly="True" Background="Transparent" BorderThickness="0" Foreground="#8FA3BF"
                 FontFamily="Consolas" FontSize="11.5" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Margin="14,10"/>
      </Border>
    </Grid>
  </Grid>
</Window>
'@

$w = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader ([xml]$xaml)))
foreach ($n in 'NavDiag', 'NavWin', 'NavGuide', 'NavTut', 'PanelDiag', 'PanelWin', 'PanelGuide', 'GuideHost', 'PanelTut', 'SysOS', 'SysGPU', 'GpuInfo', 'BtnScan', 'Findings',
    'GpuTweaks', 'BtnApplyGpu', 'BtnOpenPanel', 'BtnDriver', 'BtnWinGfx', 'VendorGuide', 'OsInfo', 'BtnRestore', 'WinTweaks',
    'BtnApplyWin', 'BtnRecommended', 'BtnUndo', 'TutorialHost', 'LogBox') {
    Set-Variable -Name $n -Value $w.FindName($n) -Scope Script
}
$script:LogBox = $LogBox

function Safe([scriptblock]$sb) {
    try { & $sb } catch { Write-Log ('Erro: ' + $_.Exception.Message) } finally { $w.Cursor = $null; $BtnScan.IsEnabled = $true }
}

function Show-Panel($name) {
    $map = @{ Diag = @($PanelDiag, $NavDiag); Win = @($PanelWin, $NavWin); Guide = @($PanelGuide, $NavGuide); Tut = @($PanelTut, $NavTut) }
    foreach ($k in $map.Keys) {
        $on = ($k -eq $name)
        if ($on) { $map[$k][0].Visibility = 'Visible'; $map[$k][1].Background = (Brush '#1B2A47') }
        else { $map[$k][0].Visibility = 'Collapsed'; $map[$k][1].Background = (Brush '#00000000') }
    }
}

# ---------- Montagem das listas de ajustes ----------
function New-TweakCheck($t) {
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Tag = $t.Id
    $cb.IsChecked = [bool]$t.Default
    $cb.Margin = [Windows.Thickness]::new(0, 0, 0, 12)
    $cb.VerticalContentAlignment = 'Top'
    $sp = New-Object System.Windows.Controls.StackPanel
    $a = New-Object System.Windows.Controls.TextBlock
    $a.Text = $t.Name; $a.FontWeight = [Windows.FontWeights]::SemiBold; $a.Margin = [Windows.Thickness]::new(6, 0, 0, 0)
    $b = New-Object System.Windows.Controls.TextBlock
    $b.Text = $t.Desc; $b.Foreground = (Brush '#8FA3BF'); $b.TextWrapping = 'Wrap'; $b.FontSize = 12; $b.MaxWidth = 680
    $b.HorizontalAlignment = 'Left'; $b.Margin = [Windows.Thickness]::new(6, 2, 0, 0)
    $sp.Children.Add($a) | Out-Null; $sp.Children.Add($b) | Out-Null
    $cb.Content = $sp
    return $cb
}
foreach ($t in $Tweaks) {
    if ($t.OS -ne 'All' -and $t.OS -ne $(if ($IsWin11) { '11' } else { '10' })) { continue }
    if ($t.Group -eq 'GPU') { $GpuTweaks.Children.Add((New-TweakCheck $t)) | Out-Null }
    else { $WinTweaks.Children.Add((New-TweakCheck $t)) | Out-Null }
}

function Add-FindingUI($status, $title, $detail, $big = $false) {
    $color = '#60A5FA'; $icon = 'ℹ'
    switch ($status) {
        'ok' { $color = '#34D399'; $icon = '✔' }
        'warn' { $color = '#FBBF24'; $icon = '⚠' }
        'bad' { $color = '#F87171'; $icon = '✖' }
    }
    $border = New-Object System.Windows.Controls.Border
    $border.Background = (Brush '#131F36'); $border.CornerRadius = [Windows.CornerRadius]::new(10)
    $border.Padding = [Windows.Thickness]::new(14, 12, 14, 12); $border.Margin = [Windows.Thickness]::new(0, 0, 0, 8)
    $border.BorderBrush = (Brush $color); $border.BorderThickness = [Windows.Thickness]::new(3, 0, 0, 0)
    $g = New-Object System.Windows.Controls.Grid
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = [Windows.GridLength]::Auto
    $c2 = New-Object System.Windows.Controls.ColumnDefinition
    $g.ColumnDefinitions.Add($c1); $g.ColumnDefinitions.Add($c2)
    $ic = New-Object System.Windows.Controls.TextBlock
    $ic.Text = $icon; $ic.FontSize = 20; $ic.Foreground = (Brush $color); $ic.Margin = [Windows.Thickness]::new(0, 0, 14, 0); $ic.VerticalAlignment = 'Top'
    $sp = New-Object System.Windows.Controls.StackPanel
    $tt = New-Object System.Windows.Controls.TextBlock
    $tt.Text = $title; $tt.FontWeight = [Windows.FontWeights]::SemiBold; $tt.TextWrapping = 'Wrap'
    if ($big) { $tt.FontSize = 16 }
    $sp.Children.Add($tt) | Out-Null
    if ($detail) {
        $dd = New-Object System.Windows.Controls.TextBlock
        $dd.Text = $detail; $dd.Foreground = (Brush '#9FB2CC'); $dd.TextWrapping = 'Wrap'; $dd.FontSize = 12; $dd.Margin = [Windows.Thickness]::new(0, 3, 0, 0)
        $sp.Children.Add($dd) | Out-Null
    }
    [Windows.Controls.Grid]::SetColumn($sp, 1)
    $g.Children.Add($ic) | Out-Null; $g.Children.Add($sp) | Out-Null
    $border.Child = $g
    $Findings.Children.Add($border) | Out-Null
}

# ---------- Guias por fabricante ----------
function Get-VendorGuide($v) {
    switch ($v) {
        'AMD' {
            return @"
Abra o AMD Software: Adrenalin Edition > Jogos > Gráficos (os nomes variam um pouco conforme a versão):

•  Perfil gráfico: Padrão (ou eSports em jogos competitivos)
•  Radeon Anti-Lag: ligado em jogos competitivos. Em jogos com anti-cheat, prefira o recurso embutido no próprio jogo
•  Radeon Boost, Radeon Chill e Enhanced Sync: desligados para desempenho máximo
•  Esperar atualização vertical: desligado (ou Melhorado se houver tearing sem FreeSync)
•  Qualidade de filtragem de textura: Desempenho
•  Cache de shaders: AMD otimizado
•  Tela > AMD FreeSync: ligado, se o seu monitor suportar
•  Smart Access Memory: ligado (ative o Resizable BAR na BIOS)
•  Limite de FPS: desligado, ou 3 FPS abaixo da taxa do monitor para menos latência
"@
        }
        'NVIDIA' {
            return @"
Abra o Painel de Controle NVIDIA > Gerenciar configurações 3D > Configurações globais:

•  Modo de gerenciamento de energia: Preferir desempenho máximo
•  Modo de baixa latência: Ligado (Ultra em jogos competitivos sem NVIDIA Reflex)
•  Sincronização vertical: Desligada (ou use G-SYNC se o monitor suportar)
•  Qualidade de filtragem de textura: Alto desempenho
•  Cache de sombreador: Padrão do driver
•  Filtragem anisotrópica e suavização: controladas pelo aplicativo (o jogo decide)
•  Ative o Resizable BAR na BIOS, se a placa e a placa-mãe suportarem
•  No NVIDIA App ou GeForce Experience: desligue a otimização automática de jogos se preferir controle manual
"@
        }
        'Intel' {
            return @"
Abra o Intel Graphics Software (ou Graphics Command Center):

•  Energia: modo Desempenho máximo quando estiver na tomada
•  Sincronização vertical: Desligada (ou Adaptive Sync, se o monitor suportar)
•  Ative o Resizable BAR na BIOS. Em placas Intel Arc isso faz muita diferença
•  Mantenha o driver sempre atualizado: placas Arc melhoram bastante a cada versão
"@
        }
        default { return 'Não identifiquei o fabricante da placa. Instale o driver oficial do fabricante e rode a análise novamente.' }
    }
}

# ---------- Diagnóstico ----------
function Invoke-Scan {
    $w.Cursor = [System.Windows.Input.Cursors]::Wait
    $BtnScan.IsEnabled = $false
    $Findings.Children.Clear()
    $res = New-Object System.Collections.ArrayList
    $add = { param($s, $t, $d) [void]$res.Add([pscustomobject]@{ S = $s; T = $t; D = $d }) }
    Write-Log 'Analisando a placa de vídeo...'
    DoEvents

    $gpus = @(Get-Gpus)
    $script:Gpus = $gpus
    if ($gpus.Count -eq 0) {
        & $add 'bad' 'Nenhuma placa de vídeo detectada' 'O Windows não listou nenhuma GPU. Confira o encaixe da placa, os cabos de energia dela e instale o driver do fabricante.'
        $GpuInfo.Text = 'Nenhuma placa de vídeo encontrada.'
    } else {
        $primary = $gpus | Where-Object { $_.Dedicated } | Select-Object -First 1
        if (-not $primary) { $primary = $gpus | Where-Object { $_.Vendor -eq 'AMD' -or $_.Vendor -eq 'NVIDIA' } | Select-Object -First 1 }
        if (-not $primary) { $primary = $gpus[0] }
        $script:Vendor = $primary.Vendor
        $o = $primary.Obj

        # Texto de informações
        $lines = @()
        foreach ($g in $gpus) {
            $go = $g.Obj
            $vr = 'memória n/d'; if ($g.VramGB) { $vr = "$($g.VramGB) GB de memória" }
            $dd = 'n/d'; if ($go.DriverDate) { $dd = ([datetime]$go.DriverDate).ToString('dd/MM/yyyy') }
            $lines += "$($g.Name)  •  $vr  •  driver $($go.DriverVersion) ($dd)"
        }
        if ($o.CurrentHorizontalResolution) { $lines += "Tela: $($o.CurrentHorizontalResolution) x $($o.CurrentVerticalResolution) a $($o.CurrentRefreshRate) Hz" }
        $GpuInfo.Text = ($lines -join "`n")
        $SysGPU.Text = $primary.Name
        $VendorGuide.Text = Get-VendorGuide $script:Vendor
        DoEvents

        # 1) Driver instalado
        if ($primary.Name -match 'Basic Display|Basic Render') {
            & $add 'bad' 'Driver de vídeo não instalado' 'O Windows está usando o driver genérico, que é lento e não tem recursos de jogo. Baixe o driver oficial do fabricante da placa (botão Baixar driver).'
        }
        # 2) Erro no dispositivo
        if ($o.ConfigManagerErrorCode -and $o.ConfigManagerErrorCode -ne 0) {
            & $add 'bad' "O Windows reporta erro na placa de vídeo (código $($o.ConfigManagerErrorCode))" 'Reinstale o driver. Se persistir, verifique o encaixe e a alimentação da placa.'
        } elseif ($primary.Name -notmatch 'Basic Display|Basic Render') {
            & $add 'ok' 'A placa de vídeo está funcionando normalmente' 'Nenhum erro de dispositivo foi reportado pelo Windows.'
        }
        # 3) Idade do driver
        if ($o.DriverDate) {
            $days = [int]((Get-Date) - [datetime]$o.DriverDate).TotalDays
            $verTxt = $o.DriverVersion
            if ($primary.Vendor -eq 'NVIDIA') { $verTxt = (Get-NvidiaVer $o.DriverVersion) + " ($($o.DriverVersion))" }
            $months = [math]::Round($days / 30)
            if ($days -gt 240) { & $add 'warn' 'Driver de vídeo desatualizado' "Versão $verTxt, com cerca de $months meses. Drivers novos corrigem travamentos e melhoram o desempenho em jogos recentes. Use o botão Baixar driver." }
            else { & $add 'ok' 'Driver de vídeo atualizado' "Versão $verTxt (cerca de $months meses)." }
        }
        DoEvents

        # 4) Falhas do driver nos últimos 14 dias
        try {
            $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Display', 'nvlddmkm', 'amdkmdag', 'amdkmdap'; Level = 1, 2, 3; StartTime = (Get-Date).AddDays(-14) } -ErrorAction SilentlyContinue)
            if ($ev.Count -gt 0) {
                $last = ($ev | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated.ToString('dd/MM/yyyy HH:mm')
                & $add 'bad' "O driver de vídeo travou $($ev.Count) vez(es) nos últimos 14 dias" "Última falha em $last. Isso causa telas pretas e jogos fechando. Reinstale o driver (use a instalação limpa do instalador), confira temperaturas e a fonte de energia do PC."
            } else {
                & $add 'ok' 'Nenhuma falha do driver nos últimos 14 dias' $null
            }
        } catch {}

        # 5) Temperatura e uso (NVIDIA tem nvidia-smi)
        if ($primary.Vendor -eq 'NVIDIA') {
            try {
                $smi = $null
                foreach ($c in @("$($env:SystemRoot)\System32\nvidia-smi.exe", "$($env:ProgramFiles)\NVIDIA Corporation\NVSMI\nvidia-smi.exe")) { if (Test-Path $c) { $smi = $c; break } }
                if ($smi) {
                    $q = @(& $smi '--query-gpu=temperature.gpu,utilization.gpu,memory.used,memory.total' '--format=csv,noheader,nounits' 2>$null) | Select-Object -First 1
                    $parts = "$q".Split(',') | ForEach-Object { $_.Trim() }
                    if ($parts.Count -ge 4) {
                        $temp = [int]$parts[0]
                        $detail = "Uso da GPU $($parts[1])%  •  memória de vídeo $($parts[2]) de $($parts[3]) MB."
                        if ($temp -ge 90) { & $add 'bad' "Temperatura da GPU muito alta ($temp °C)" "$detail Limpe o pó, confira os coolers e o fluxo de ar do gabinete." }
                        elseif ($temp -ge 80) { & $add 'warn' "Temperatura da GPU elevada ($temp °C)" "$detail Normal em jogo pesado, preocupante se estiver sem fazer nada." }
                        else { & $add 'ok' "Temperatura da GPU normal ($temp °C)" $detail }
                    }
                }
            } catch {}
        }
        DoEvents

        # 6) Agendamento de GPU acelerado por hardware
        $hags = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name HwSchMode -ErrorAction SilentlyContinue).HwSchMode
        if ($hags -eq 2) { & $add 'ok' 'Agendamento de GPU por hardware está ligado' $null }
        else { & $add 'info' 'Agendamento de GPU por hardware está desligado' 'Opcional. Em placas recentes pode melhorar a fluidez. Está na lista de ajustes abaixo, desmarcado por padrão.' }

        # 7) Modo de Jogo
        $gm = (Get-ItemProperty 'HKCU:\Software\Microsoft\GameBar' -Name AutoGameModeEnabled -ErrorAction SilentlyContinue).AutoGameModeEnabled
        if ($gm -eq 0) { & $add 'warn' 'Modo de Jogo do Windows está desligado' 'Ligue para o Windows priorizar o jogo (ajuste disponível abaixo).' }
        else { & $add 'ok' 'Modo de Jogo do Windows está ligado' $null }

        # 8) Game DVR
        $d1 = (Get-ItemProperty 'HKCU:\System\GameConfigStore' -Name GameDVR_Enabled -ErrorAction SilentlyContinue).GameDVR_Enabled
        $d2 = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Name AppCaptureEnabled -ErrorAction SilentlyContinue).AppCaptureEnabled
        if ($d1 -eq 1 -or $d2 -eq 1) { & $add 'warn' 'Gravação em segundo plano (Game DVR) está ativa' 'Ela usa a GPU o tempo todo e pode derrubar o FPS. Desative no ajuste abaixo.' }
        else { & $add 'ok' 'Gravação em segundo plano está desativada' $null }

        # 9) Plano de energia
        try {
            $pp = (& powercfg /getactivescheme) -join ' '
            if ($pp -match 'a1841308-3541-4fab-bc81-f71556f20b4a') { & $add 'warn' 'Plano de energia em Economia de energia' 'Reduz bastante o desempenho da GPU e do processador. Troque para desempenho máximo (ajuste abaixo).' }
            elseif ($pp -match '381b4222-f694-41f0-9685-ff5bb260df2e') { & $add 'info' 'Plano de energia Equilibrado' 'Funciona bem no dia a dia. Para jogar, o plano de desempenho máximo tira oscilações de velocidade.' }
            elseif ($pp -match 'Ultimate|Alto desempenho|High performance|Desempenho m[aáà]ximo|8c5e7fda|e9a42b02') { & $add 'ok' 'Plano de energia de alto desempenho ativo' $null }
            else { & $add 'info' 'Plano de energia personalizado' 'Provavelmente do fabricante do PC. Está tudo bem, mas você pode trocar no ajuste abaixo.' }
        } catch {}

        # 10) Taxa de atualização
        if ($o.CurrentRefreshRate) {
            if ([int]$o.CurrentRefreshRate -le 60) { & $add 'info' "Monitor em $($o.CurrentRefreshRate) Hz" 'Se o seu monitor for de 120, 144 ou 165 Hz, escolha a taxa máxima em Configurações > Sistema > Tela > Taxa de atualização.' }
            else { & $add 'ok' "Monitor em $($o.CurrentRefreshRate) Hz" $null }
        }

        # 11) Notebook com duas GPUs
        if ($gpus.Count -gt 1 -and @($gpus | Where-Object { $_.Dedicated }).Count -gt 0 -and @($gpus | Where-Object { -not $_.Dedicated }).Count -gt 0) {
            & $add 'info' 'Este PC tem duas GPUs (integrada e dedicada)' 'Garanta que seus jogos usem a dedicada: clique em Gráficos do Windows e escolha Alto desempenho para cada jogo.'
        }

        # 12) Espaço em disco
        try {
            $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'"
            $free = [math]::Round($disk.FreeSpace / 1GB, 1)
            if ($free -lt 10) { & $add 'warn' "Pouco espaço livre no disco do Windows ($free GB)" 'Abaixo de 10 GB o Windows e os jogos ficam lentos. Libere espaço (ajuste Limpar arquivos temporários ajuda).' }
            else { & $add 'ok' "Espaço livre no disco do Windows: $free GB" $null }
        } catch {}

        # 13) Painel do fabricante instalado
        try {
            $pat = switch ($primary.Vendor) { 'AMD' { 'AMD Software|Radeon|Adrenalin' } 'NVIDIA' { 'NVIDIA (Control Panel|App)|GeForce Experience' } 'Intel' { 'Intel.*(Graphics|Arc)' } default { $null } }
            if ($pat) {
                $app = Get-StartApps | Where-Object { $_.Name -match $pat } | Select-Object -First 1
                if (-not $app) { & $add 'warn' 'Painel de controle da placa não encontrado' 'Sem o software do fabricante você perde recursos e ajustes. Baixe o driver completo (botão Baixar driver).' }
            }
        } catch {}
    }

    # Resumo + lista ordenada
    $nBad = @($res | Where-Object { $_.S -eq 'bad' }).Count
    $nWarn = @($res | Where-Object { $_.S -eq 'warn' }).Count
    if ($nBad -gt 0) { Add-FindingUI 'bad' "$nBad problema(s) e $nWarn aviso(s) encontrados" 'Veja abaixo o que fazer em cada caso.' $true }
    elseif ($nWarn -gt 0) { Add-FindingUI 'warn' "$nWarn aviso(s) encontrado(s), nada grave" 'Dá para melhorar o desempenho com os ajustes recomendados.' $true }
    else { Add-FindingUI 'ok' 'Tudo certo com a sua placa de vídeo' 'Nenhum problema encontrado.' $true }
    $order = @{ bad = 0; warn = 1; info = 2; ok = 3 }
    foreach ($r in @($res | Sort-Object { $order[$_.S] })) { Add-FindingUI $r.S $r.T $r.D }

    $script:Scanned = $true
    Write-Log "Análise concluída: $nBad problema(s), $nWarn aviso(s)."
}

# ---------- Aplicar ajustes ----------
function Invoke-Apply($panel) {
    $sel = @($panel.Children | Where-Object { $_.IsChecked -eq $true })
    if ($sel.Count -eq 0) { Write-Log 'Nenhum ajuste marcado.'; return }
    $w.Cursor = [System.Windows.Input.Cursors]::Wait
    if (-not $script:RestoreDone) { $script:RestoreDone = New-RestorePoint }
    $reboot = $false
    $done = 0
    foreach ($cb in $sel) {
        $t = $Tweaks | Where-Object { $_.Id -eq $cb.Tag } | Select-Object -First 1
        Write-Log "Aplicando: $($t.Name)..."
        DoEvents
        try {
            $msg = Invoke-Tweak $t
            Write-Log "  OK: $msg"
            $done++
            if ($t.Reboot) { $reboot = $true }
        } catch { Write-Log "  Falhou: $($_.Exception.Message)" }
    }
    Write-Log "Concluído: $done de $($sel.Count) ajustes aplicados."
    $text = "$done de $($sel.Count) ajustes aplicados."
    if ($reboot) { $text += "`n`nReinicie o PC para o Agendamento de GPU entrar em vigor." }
    else { $text += "`n`nAlguns efeitos visuais só aparecem depois de sair e entrar na conta do Windows, ou de reiniciar." }
    [System.Windows.MessageBox]::Show($text, 'Otimizador GPU', 'OK', 'Information') | Out-Null
}

# ---------- Tutorial ----------
$tutorial = @(
    @{ T = '1. Bem-vindo'
        B = "Este programa faz duas coisas: examina sua placa de vídeo atrás de problemas e aplica ajustes para ganhar desempenho em jogos e no Windows em geral.`n`nTudo é feito com os recursos do próprio Windows. Nada é instalado, nada é baixado e nenhum serviço essencial é desativado." },
    @{ T = '2. Diagnóstico da GPU'
        B = "Ao abrir, a análise roda sozinha (ou clique em Analisar agora). Ela verifica driver, falhas recentes, temperatura (placas NVIDIA), plano de energia, Modo de Jogo, gravação em segundo plano, taxa do monitor e espaço em disco.`n`nCores: verde = ok, amarelo = aviso, vermelho = problema, azul = informação ou dica. Os itens mais importantes aparecem primeiro." },
    @{ T = '3. Aplicar ajustes de GPU'
        B = "Na própria aba de diagnóstico, marque os ajustes que quiser e clique em Aplicar ajustes marcados. Os marcados por padrão são seguros para a maioria dos PCs. Os opcionais vêm desmarcados.`n`nAntes de mudar qualquer coisa o programa cria um ponto de restauração do Windows e guarda os valores originais." },
    @{ T = '4. Painel da placa (Adrenalin, NVIDIA, Intel)'
        B = "O fabricante não oferece forma pública para outros programas alterarem as opções do Adrenalin ou do Painel NVIDIA. Por isso o programa faz duas coisas: abre o painel para você (botão Abrir painel da placa) e mostra a lista exata do que marcar, abaixo do diagnóstico. A aba Guia visual Adrenalin mostra isso em ilustrações, tela por tela.`n`nSe o painel não abrir, o driver completo provavelmente não está instalado. Use o botão Baixar driver." },
    @{ T = '5. Otimizador Windows'
        B = "O programa identifica se você usa Windows 10 ou 11 e mostra só as otimizações que valem para a sua versão. Marque as que quiser (as recomendadas já vêm marcadas) e clique em Aplicar selecionadas.`n`nO que ele NÃO faz: não mexe no antivírus, no Windows Update, nem desativa serviços do sistema, e não faz overclock." },
    @{ T = '6. Desfazer'
        B = "Não gostou de algo? Clique em Desfazer tudo na aba Otimizador Windows e todos os valores voltam ao que eram. Também dá para voltar pelo ponto de restauração (Painel de Controle > Recuperação).`n`nOs registros ficam em C:\ProgramData\OtimizadorGPU (arquivos log.txt e desfazer.json). Limpezas de arquivos não têm desfazer." },
    @{ T = '7. Dicas que fazem diferença'
        B = "•  Ao instalar um driver novo, escolha Instalação personalizada > Instalação limpa (NVIDIA) ou Reinício de fábrica (AMD).`n•  Ative o Resizable BAR (Smart Access Memory na AMD) na BIOS, se a placa e a placa-mãe suportarem.`n•  Memória RAM em dois pentes e com XMP ou EXPO ligado ajuda muito o FPS.`n•  Limpe o pó do gabinete a cada 6 meses. Temperatura alta derruba o desempenho.`n•  Em notebook, deixe na tomada e use o modo Desempenho." }
)
foreach ($s in $tutorial) {
    $b = New-Object System.Windows.Controls.Border
    $b.Background = (Brush '#131F36'); $b.CornerRadius = [Windows.CornerRadius]::new(12)
    $b.Padding = [Windows.Thickness]::new(18); $b.Margin = [Windows.Thickness]::new(0, 0, 0, 12)
    $sp = New-Object System.Windows.Controls.StackPanel
    $h = New-Object System.Windows.Controls.TextBlock
    $h.Text = $s.T; $h.FontSize = 15; $h.FontWeight = [Windows.FontWeights]::SemiBold; $h.Foreground = (Brush '#22D3EE'); $h.Margin = [Windows.Thickness]::new(0, 0, 0, 8)
    $p = New-Object System.Windows.Controls.TextBlock
    $p.Text = $s.B; $p.TextWrapping = 'Wrap'; $p.LineHeight = 22
    $sp.Children.Add($h) | Out-Null; $sp.Children.Add($p) | Out-Null
    $b.Child = $sp
    $TutorialHost.Children.Add($b) | Out-Null
}

# ---------- Guia visual do Adrenalin (ilustracoes desenhadas pelo proprio app) ----------
function New-GuideTag($kind) {
    $txt = 'Opcional'; $col = '#9FB2CC'; $bg = '#1B2A47'
    switch ($kind) {
        'rec' { $txt = 'Recomendado'; $col = '#22D3EE'; $bg = '#0E3A47' }
        'keep' { $txt = 'Deixe no padrão'; $col = '#34D399'; $bg = '#0F3B2E' }
        'opt' { $txt = 'Opcional'; $col = '#9FB2CC'; $bg = '#1B2A47' }
        'warn' { $txt = 'Cuidado'; $col = '#FBBF24'; $bg = '#4A3A0F' }
    }
    $b = New-Object System.Windows.Controls.Border
    $b.Background = (Brush $bg); $b.CornerRadius = [Windows.CornerRadius]::new(10)
    $b.Padding = [Windows.Thickness]::new(9, 2, 9, 3); $b.VerticalAlignment = 'Top'; $b.Margin = [Windows.Thickness]::new(12, 1, 0, 0)
    $tx = New-Object System.Windows.Controls.TextBlock
    $tx.Text = $txt; $tx.FontSize = 11; $tx.Foreground = (Brush $col); $tx.FontWeight = [Windows.FontWeights]::SemiBold
    $b.Child = $tx
    return $b
}

function New-GuideControl($kind, $value) {
    if ($kind -eq 'on' -or $kind -eq 'off') {
        $isOn = ($kind -eq 'on')
        $bd = New-Object System.Windows.Controls.Border
        $bd.Width = 46; $bd.Height = 24; $bd.CornerRadius = [Windows.CornerRadius]::new(12)
        if ($isOn) { $bd.Background = (Brush '#22D3EE') } else { $bd.Background = (Brush '#475569') }
        $el = New-Object System.Windows.Shapes.Ellipse
        $el.Width = 18; $el.Height = 18; $el.Fill = (Brush '#FFFFFF'); $el.VerticalAlignment = 'Center'
        $el.Margin = [Windows.Thickness]::new(3, 0, 3, 0)
        if ($isOn) { $el.HorizontalAlignment = 'Right' } else { $el.HorizontalAlignment = 'Left' }
        $bd.Child = $el
        $lb = New-Object System.Windows.Controls.TextBlock
        if ($isOn) { $lb.Text = 'Ligado' } else { $lb.Text = 'Desligado' }
        $lb.Foreground = (Brush '#8FA3BF'); $lb.FontSize = 12; $lb.VerticalAlignment = 'Center'; $lb.Margin = [Windows.Thickness]::new(8, 0, 0, 0)
        $row = New-Object System.Windows.Controls.StackPanel
        $row.Orientation = 'Horizontal'; $row.MinWidth = 150
        $row.Children.Add($bd) | Out-Null; $row.Children.Add($lb) | Out-Null
        return $row
    }
    $box = New-Object System.Windows.Controls.Border
    $box.Background = (Brush '#1B2A47'); $box.BorderBrush = (Brush '#2B3C5E'); $box.BorderThickness = [Windows.Thickness]::new(1)
    $box.CornerRadius = [Windows.CornerRadius]::new(6); $box.Padding = [Windows.Thickness]::new(12, 4, 12, 5); $box.MinWidth = 150
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = "$value   ▾"; $tb.FontSize = 12.5
    $box.Child = $tb
    return $box
}

function Add-GuideRow($rows, $label, $kind, $value, $note, $tag) {
    $g = New-Object System.Windows.Controls.Grid
    $g.Margin = [Windows.Thickness]::new(0, 0, 0, 16)
    $c0 = New-Object System.Windows.Controls.ColumnDefinition; $c0.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
    $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = [Windows.GridLength]::Auto
    $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = [Windows.GridLength]::Auto
    $g.ColumnDefinitions.Add($c0); $g.ColumnDefinitions.Add($c1); $g.ColumnDefinitions.Add($c2)
    $sp = New-Object System.Windows.Controls.StackPanel
    $l1 = New-Object System.Windows.Controls.TextBlock
    $l1.Text = $label; $l1.FontWeight = [Windows.FontWeights]::SemiBold; $l1.TextWrapping = 'Wrap'
    $sp.Children.Add($l1) | Out-Null
    if ($note) {
        $l2 = New-Object System.Windows.Controls.TextBlock
        $l2.Text = $note; $l2.Foreground = (Brush '#9FB2CC'); $l2.FontSize = 12; $l2.TextWrapping = 'Wrap'
        $l2.Margin = [Windows.Thickness]::new(0, 2, 12, 0)
        $sp.Children.Add($l2) | Out-Null
    }
    $ctl = New-GuideControl $kind $value
    $ctl.VerticalAlignment = 'Top'
    [Windows.Controls.Grid]::SetColumn($ctl, 1)
    $tg = New-GuideTag $tag
    [Windows.Controls.Grid]::SetColumn($tg, 2)
    $g.Children.Add($sp) | Out-Null; $g.Children.Add($ctl) | Out-Null; $g.Children.Add($tg) | Out-Null
    $rows.Children.Add($g) | Out-Null
}

function New-GuideSection($crumb, $intro) {
    $outer = New-Object System.Windows.Controls.Border
    $outer.Background = (Brush '#131F36'); $outer.CornerRadius = [Windows.CornerRadius]::new(12); $outer.Margin = [Windows.Thickness]::new(0, 0, 0, 20)
    $stack = New-Object System.Windows.Controls.StackPanel
    $head = New-Object System.Windows.Controls.Border
    $head.Background = (Brush '#1B2A47'); $head.CornerRadius = [Windows.CornerRadius]::new(12, 12, 0, 0); $head.Padding = [Windows.Thickness]::new(18, 12, 18, 12)
    $hc = New-Object System.Windows.Controls.TextBlock
    $hc.Text = $crumb; $hc.FontWeight = [Windows.FontWeights]::SemiBold; $hc.Foreground = (Brush '#22D3EE')
    $head.Child = $hc
    $body = New-Object System.Windows.Controls.StackPanel
    $body.Margin = [Windows.Thickness]::new(18, 16, 18, 4)
    if ($intro) {
        $ti = New-Object System.Windows.Controls.TextBlock
        $ti.Text = $intro; $ti.Foreground = (Brush '#9FB2CC'); $ti.TextWrapping = 'Wrap'; $ti.Margin = [Windows.Thickness]::new(0, 0, 0, 16)
        $body.Children.Add($ti) | Out-Null
    }
    $stack.Children.Add($head) | Out-Null; $stack.Children.Add($body) | Out-Null
    $outer.Child = $stack
    $GuideHost.Children.Add($outer) | Out-Null
    return $body
}

$capt = New-Object System.Windows.Controls.TextBlock
$capt.Text = "Estas são ilustrações feitas para este guia, não prints oficiais da AMD. O nome e o lugar das opções mudam conforme a versão do Adrenalin, o idioma e o modelo da placa. Se não achar uma opção, use a busca do próprio Adrenalin digitando o nome dela."
$capt.Foreground = (Brush '#8FA3BF'); $capt.FontSize = 12; $capt.TextWrapping = 'Wrap'; $capt.Margin = [Windows.Thickness]::new(0, 0, 0, 16)
$GuideHost.Children.Add($capt) | Out-Null

$gA = New-GuideSection 'Adrenalin  ›  Jogos  ›  Gráficos  ›  Gráficos globais' 'Vale para todos os jogos. Cada jogo pode ter um perfil próprio que sobrepõe estes valores.'
Add-GuideRow $gA 'Radeon Anti-Lag' 'on' '' 'Menos atraso entre o clique e a imagem. Em jogos competitivos com anti-cheat, prefira o recurso de baixa latência do próprio jogo.' 'rec'
Add-GuideRow $gA 'Radeon Boost' 'off' '' 'Baixa a resolução em movimento para ganhar FPS, só em jogos suportados. Desligado mantém a imagem sempre nítida.' 'rec'
Add-GuideRow $gA 'Radeon Chill' 'off' '' 'Limita o FPS para esquentar menos. Para desempenho máximo, deixe desligado.' 'rec'
Add-GuideRow $gA 'Radeon Enhanced Sync' 'off' '' $null 'rec'
Add-GuideRow $gA 'Esperar atualização vertical' 'drop' 'Desligado, a menos que o aplicativo especifique' 'Evita travar o FPS no valor do monitor.' 'rec'
Add-GuideRow $gA 'Qualidade de filtragem de textura' 'drop' 'Desempenho' $null 'rec'
Add-GuideRow $gA 'Modo de tesselação' 'drop' 'AMD otimizado' $null 'keep'
Add-GuideRow $gA 'Cache de shaders' 'drop' 'AMD otimizado' 'Se tiver travadinhas depois de trocar o driver, use a limpeza de cache de shaders na aba Diagnóstico.' 'keep'

$gB = New-GuideSection 'Adrenalin  ›  Tela (Display)' 'Se a sua aba Vídeo mostrar outros itens além destes, me mande um print dela para eu acrescentar aqui.'
Add-GuideRow $gB 'AMD FreeSync' 'on' '' 'Sincroniza a imagem com o monitor sem travar o FPS. Só aparece se o monitor e o cabo suportarem.' 'rec'
Add-GuideRow $gB 'Escala de GPU (GPU Scaling)' 'off' '' 'Só ligue se jogar numa resolução menor que a do monitor. A tela fica preta por um instante ao ligar, é normal.' 'opt'
Add-GuideRow $gB 'Super Resolução Virtual' 'off' '' 'Renderiza em resolução maior que a do monitor, o que pesa na placa.' 'rec'

$gC = New-GuideSection 'Adrenalin  ›  Desempenho  ›  Ajuste (Performance Tuning)' 'Para o melhor desempenho sem problemas, o mais seguro é deixar tudo no Padrão. O ganho de forçar a placa costuma ser pequeno, e sair das especificações da AMD não tem cobertura de garantia.'
Add-GuideRow $gC 'Sistema  ›  Ajuste automático' 'drop' 'Padrão' 'Auto Overclock existe, mas roda a placa fora da especificação.' 'keep'
Add-GuideRow $gC 'GPU  ›  Ajuste automático' 'drop' 'Padrão' 'Undervolt GPU é a opção mais tranquila se quiser esfriar a placa. Overclock GPU e Overclock VRAM dependem do modelo.' 'keep'
Add-GuideRow $gC 'GPU  ›  Predefinição de ajuste' 'drop' 'Balanced (Equilibrado)' 'Existem Quiet, Balanced e Rage (RX 6000 e mais novas). Rage força mais e esquenta mais.' 'keep'
Add-GuideRow $gC 'Ajuste manual (Custom)' 'off' '' 'Libera os controles de frequência e tensão. O Adrenalin pede que você aceite um aviso de risco antes.' 'warn'
Add-GuideRow $gC 'Ajuste de VRAM  ›  Temporização da memória' 'drop' 'Default (Padrão)' 'Fast (Rápido) existe em placas RX 5000 e mais novas e pode causar travamentos. Se testar, rode o Teste de estresse do próprio Adrenalin.' 'opt'
Add-GuideRow $gC 'Smart Access Memory' 'on' '' 'Liga sozinho em PCs compatíveis (precisa do Resizable BAR na BIOS). Ao alternar, o Adrenalin reinicia e a tela pode ficar preta: feche os jogos antes.' 'rec'
Add-GuideRow $gC 'Ajuste do ventilador  ›  Zero RPM' 'on' '' 'Padrão da AMD: os ventiladores param com a placa fria e giram quando ela esquenta.' 'keep'
Add-GuideRow $gC 'Ajuste de energia  ›  Limite de energia' 'drop' '0% (padrão)' 'Aumentar dá folga de desempenho, mas a placa consome e esquenta mais.' 'opt'

# ---------- Textos fixos ----------
$verTxt = ''; if ($WinVer) { $verTxt = " ($WinVer)" }
$SysOS.Text = "$WinName`nbuild $Build$verTxt"
$osNum = '10'; if ($IsWin11) { $osNum = '11' }
$OsInfo.Text = "Detectado: Windows $osNum  •  $WinName  •  build $Build$verTxt. Mostrando as otimizações que valem para a sua versão."
$SysGPU.Text = 'Detectando placa...'

# ---------- Eventos ----------
$NavDiag.Add_Click({ Show-Panel 'Diag' })
$NavWin.Add_Click({ Show-Panel 'Win' })
$NavGuide.Add_Click({ Show-Panel 'Guide' })
$NavTut.Add_Click({ Show-Panel 'Tut' })

$BtnScan.Add_Click({ Safe { Invoke-Scan } })
$BtnApplyGpu.Add_Click({ Safe { Invoke-Apply $GpuTweaks; Invoke-Scan } })
$BtnApplyWin.Add_Click({ Safe { Invoke-Apply $WinTweaks } })
$BtnRestore.Add_Click({ Safe { if (New-RestorePoint) { $script:RestoreDone = $true } } })
$BtnRecommended.Add_Click({
    Safe {
        foreach ($cb in @($WinTweaks.Children)) {
            $t = $Tweaks | Where-Object { $_.Id -eq $cb.Tag } | Select-Object -First 1
            $cb.IsChecked = [bool]$t.Default
        }
        Write-Log 'Ajustes recomendados marcados.'
    }
})
$BtnUndo.Add_Click({
    Safe {
        if (@($script:Undo).Count -eq 0) {
            Write-Log 'Não há ajustes registrados para desfazer.'
            [System.Windows.MessageBox]::Show('Não há ajustes registrados para desfazer.', 'Desfazer tudo', 'OK', 'Information') | Out-Null
            return
        }
        $ans = [System.Windows.MessageBox]::Show('Isso devolve TODOS os ajustes feitos por este programa aos valores originais. Continuar?', 'Desfazer tudo', 'YesNo', 'Question')
        if ($ans -eq 'Yes') {
            $w.Cursor = [System.Windows.Input.Cursors]::Wait
            Invoke-UndoAll
            Write-Log 'Todos os ajustes foram desfeitos.'
            [System.Windows.MessageBox]::Show('Ajustes desfeitos. Reinicie o PC para garantir que tudo voltou ao normal.', 'Desfazer tudo', 'OK', 'Information') | Out-Null
        }
    }
})
$BtnOpenPanel.Add_Click({
    Safe {
        $pat = switch ($script:Vendor) {
            'AMD' { 'AMD Software|Radeon|Adrenalin' }
            'NVIDIA' { 'NVIDIA (Control Panel|App)|GeForce Experience' }
            'Intel' { 'Intel.*(Graphics|Arc)' }
            default { 'Radeon|NVIDIA (Control Panel|App)|Intel.*Graphics' }
        }
        $app = Get-StartApps | Where-Object { $_.Name -match $pat } | Select-Object -First 1
        if ($app) {
            Start-Process -FilePath 'explorer.exe' -ArgumentList "shell:AppsFolder\$($app.AppID)"
            Write-Log "Abrindo $($app.Name)..."
        } else {
            Write-Log 'Não encontrei o painel da placa. Instale o driver completo pelo botão Baixar driver.'
        }
    }
})
$BtnDriver.Add_Click({
    Safe {
        $url = switch ($script:Vendor) {
            'AMD' { 'https://www.amd.com/en/support/download/drivers.html' }
            'NVIDIA' { 'https://www.nvidia.com/Download/index.aspx' }
            'Intel' { 'https://www.intel.com/content/www/us/en/download-center/home.html' }
            default { 'https://www.google.com/search?q=baixar+driver+placa+de+video' }
        }
        Start-Process $url
        Write-Log 'Abrindo a página oficial de drivers no navegador.'
    }
})
$BtnWinGfx.Add_Click({ Safe { Start-Process 'ms-settings:display-advancedgraphics' } })

$w.Add_ContentRendered({
    if (-not $script:Scanned) { Safe { Invoke-Scan } }
})

# ---------- Execução ----------
try {
    Show-Panel 'Diag'
    $VendorGuide.Text = 'Rode a análise para ver as configurações do seu fabricante.'
    Write-Log "Otimizador iniciado. Windows $osNum, build $Build."
    if (@($script:Undo).Count -gt 0) { Write-Log "Há $(@($script:Undo).Count) alterações registradas que podem ser desfeitas." }
    $w.ShowDialog() | Out-Null
} catch {
    [System.Windows.MessageBox]::Show("Erro inesperado:`n$($_.Exception.Message)", 'Otimizador GPU', 'OK', 'Error') | Out-Null
    try { Add-Content -Path $LogFile -Value $_.Exception.ToString() } catch {}
}