param(
    [string] $Platform,
	[string] $Configuration,
	[string] $WorkDir,
	[string] $OutputDir,
	[switch] $NoConfig,
	[switch] $Compress
)

$ErrorActionPreference = "Stop"

New-Item -Path "$WorkDir" -Name "portable-$Platform-$Configuration" -ItemType "Directory" -Force
New-Item -Path "$OutputDir" -ItemType "Directory" -Force

# 便携包目标目录
$dest = if ($Compress) { "$WorkDir\portable-$Platform-$Configuration" } else { $OutputDir }

Copy-Item -Path "$PSScriptRoot\..\..\AppPackage\bin\$Platform\$Configuration\*" -Destination $dest -Recurse -Include @("*.exe", "*.dll", "resources.pri", "Assets")

# ---- 自包含依赖（让便携版在 Windows 10 上也能运行） ----
# Windows 10 没有动态依赖 API（api-ms-win-appmodel-runtime-l1-1-5），程序无法在运行时
# 解析 MSIX 框架包，因此把依赖的框架包 DLL（WinUI 2.8 与 VC 运行库）直接内置进便携目录，
# 由进程加载器按可执行文件所在目录优先解析。
$arch = $Platform.ToLowerInvariant()

# 1. WinUI 2.8：从 NuGet 包的 appx 中提取 Microsoft.UI.Xaml.dll，并附带资源索引。
#    资源索引使用 MRT 的 DLL 命名约定（<dll名>.pri），避免与主程序 resources.pri 冲突。
$winuiAppx = "$PSScriptRoot\..\..\packages\Microsoft.UI.Xaml.2.8.7\tools\AppX\$arch\Release\Microsoft.UI.Xaml.2.8.appx"
if (Test-Path $winuiAppx)
{
    $winuiExtract = Join-Path $dest "winui-extract"
    Expand-Archive -Path $winuiAppx -DestinationPath $winuiExtract -Force
    Copy-Item -Path "$winuiExtract\Microsoft.UI.Xaml.dll" -Destination $dest -Force
    Remove-Item -Path $winuiExtract -Recurse -Force

    $winuiPri = "$PSScriptRoot\..\..\packages\Microsoft.UI.Xaml.2.8.7\lib\uap10.0\Microsoft.UI.Xaml.pri"
    if (Test-Path $winuiPri)
    {
        Copy-Item -Path $winuiPri -Destination $dest -Force
    }
    else
    {
        Write-Warning "未找到 WinUI 2.8 资源索引 ($winuiPri)，XAML 界面可能缺少资源。"
    }
}
else
{
    Write-Warning "未找到 WinUI 2.8 框架包 ($winuiAppx)，便携版将无法加载 XAML 界面。"
}

# 2. VC 运行库：UWP 版（vcruntime140_app.dll 等，供 Xaml.dll 等 WinRT 组件使用）
#    与桌面版（vcruntime140.dll 等，供主程序使用）。
function Get-VCRedistRoot {
    if ($env:VCToolsRedistDir -and (Test-Path $env:VCToolsRedistDir))
    {
        return $env:VCToolsRedistDir
    }

    $vsRoots = @()
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}))
    {
        if (-not $base) { continue }
        $vsRoots += Get-ChildItem -Path "$base\Microsoft Visual Studio" -Directory -ErrorAction SilentlyContinue
    }

    foreach ($vs in $vsRoots)
    {
        Get-ChildItem -Path "$($vs.FullName)\VC\Redist\MSVC" -Directory -ErrorAction SilentlyContinue |
            Sort-Object { try { [version]$_.Name } catch { [version]'0.0.0.0' } } -Descending |
            Select-Object -First 1 |
            ForEach-Object { $_.FullName }
    }
}

$redist = Get-VCRedistRoot | Select-Object -First 1
if ($redist)
{
    $archDir = Join-Path $redist $arch

    $uwpCrt = Get-ChildItem -Path $archDir -Directory -Filter "Microsoft.VCLibs.140.00" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($uwpCrt)
    {
        Copy-Item -Path (Join-Path $uwpCrt.FullName "*") -Destination $dest -Force
    }
    else
    {
        Write-Warning "未找到 UWP 版 VC 运行库（$archDir\Microsoft.VCLibs.140.00）。"
    }

    $desktopCrt = Get-ChildItem -Path $archDir -Directory -Filter "Microsoft.VC*.CRT" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($desktopCrt)
    {
        Copy-Item -Path (Join-Path $desktopCrt.FullName "*.dll") -Destination $dest -Force
    }
    else
    {
        Write-Warning "未找到桌面版 VC 运行库（$archDir\Microsoft.VC*.CRT）。"
    }
}
else
{
    Write-Warning "未找到 VC Redist 目录，便携版将依赖系统已安装的 VC 运行库。"
}

if ($Compress)
{
	$platform_lower = $Platform.ToLower()
	if ($NoConfig)
	{
		$filename = "TranslucentTB-portable-$platform_lower.zip"
	}
	else
	{
		$configuration_lower = $Configuration.ToLower()
		$filename = "TranslucentTB-portable-$platform_lower-$configuration_lower.zip"
	}

	Compress-Archive -Path "$WorkDir\portable-$Platform-$Configuration\*" -DestinationPath "$OutputDir\$filename"
}

Remove-Item -Path "$WorkDir\portable-$Platform-$Configuration" -Recurse
