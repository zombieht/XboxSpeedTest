<#
.SYNOPSIS
Xbox CDN SpeedTest 的 PowerShell 版本。

.DESCRIPTION
读取 configs/cdn.list 中的 CDN IP，使用 curl.exe 执行 HTTP Range 下载测速，
找出最快 IP 后生成 hosts、SmartDNS、DNSMasq 配置文件。
#>

[CmdletBinding()]
param(
    # curl.exe 路径。默认使用系统 PATH 中的 curl.exe，避免调用 PowerShell 的 curl 别名。
    [string]$CurlPath = "curl.exe",

    # CDN IP 列表路径。
    [string]$ConfigPath = "configs/cdn.list",

    # 并发测速数量。默认 4，避免并发过高影响测速准确性。
    [int]$Jobs = 4
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$CurlMaxTime = 8
$CurlRange = "33543139328-33752035327"
$CurlSpeedTime = 5
$CurlTestUrl = "5/795514b6-aad9-4c1c-ac2a-60c1492d7f31/0c57204f-f4f0-4bf6-b119-b7afc231994d/0.0.61375.0.6574fcb5-72f2-4c85-98c1-bd1059c79934/Destiny2_0.0.61375.0_neutral__z7wx9v9k22rmg"
$CurlHost = "assets1.xboxlive.com"

function Test-CommandExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command
    )

    return $null -ne (Get-Command $Command -ErrorAction SilentlyContinue)
}

function ConvertTo-TrimmedLine {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Line
    )

    # 去除所有空白字符，兼容 Windows、Linux、macOS 的换行。
    return ($Line -replace "\s", "")
}

function Start-CdnSpeedJob {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Index,

        [Parameter(Mandatory = $true)]
        [int]$AllCount,

        [Parameter(Mandatory = $true)]
        [string]$IpAddress
    )

    # 使用后台 Job 控制并发。脚本块只依赖显式传入的参数，避免父作用域变量丢失。
    return Start-Job -ArgumentList @(
        $Index,
        $AllCount,
        $IpAddress,
        $CurlPath,
        $CurlMaxTime,
        $CurlRange,
        $CurlSpeedTime,
        $CurlTestUrl,
        $CurlHost
    ) -ScriptBlock {
        param(
            [int]$JobIndex,
            [int]$JobAllCount,
            [string]$JobIpAddress,
            [string]$JobCurlPath,
            [int]$JobCurlMaxTime,
            [string]$JobCurlRange,
            [int]$JobCurlSpeedTime,
            [string]$JobCurlTestUrl,
            [string]$JobCurlHost
        )

        $speedBytes = "0"
        $speedKb = 0

        try {
            $speedBytes = & $JobCurlPath `
                -s `
                -o NUL `
                -m $JobCurlMaxTime `
                -r $JobCurlRange `
                -y $JobCurlSpeedTime `
                --url "http://$JobIpAddress/$JobCurlTestUrl" `
                -H "Host: $JobCurlHost" `
                -w "%{speed_download}" 2>$null

            # curl 达到 -m 最大耗时时会返回 28，但 -w 仍会输出已下载阶段的速度。
            # 这里按 speed_download 是否可解析来计算速度，避免把有效测速误判为 0。
            if ($speedBytes -match "^[0-9]+(\.[0-9]+)?$") {
                $speedKb = [int][Math]::Floor([double]$speedBytes / 1024)
            }
        } catch {
            $speedKb = 0
        }

        [PSCustomObject]@{
            Index = $JobIndex
            AllCount = $JobAllCount
            IpAddress = $JobIpAddress
            SpeedKb = $speedKb
        }
    }
}

function Write-OutputFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BestIp
    )

    # 使用 CRLF 换行，保持和原 Python 脚本输出格式一致。
    $hostsContent = @(
        "$BestIp assets1.xboxlive.com"
        "$BestIp assets2.xboxlive.com"
        "$BestIp dlassets.xboxlive.com"
    ) -join "`r`n"
    Set-Content -Path "hosts_best_output.txt" -Value ($hostsContent + "`r`n") -Encoding UTF8 -NoNewline

    $smartDnsContent = @(
        "address /assets1.xboxlive.com/$BestIp"
        "address /assets2.xboxlive.com/$BestIp"
        "address /dlassets.xboxlive.com/$BestIp"
    ) -join "`r`n"
    Set-Content -Path "smartdns_best_output.txt" -Value ($smartDnsContent + "`r`n") -Encoding UTF8 -NoNewline

    $dnsMasqContent = @(
        "address=/assets1.xboxlive.com/$BestIp"
        "address=/assets2.xboxlive.com/$BestIp"
        "address=/dlassets.xboxlive.com/$BestIp"
    ) -join "`r`n"
    Set-Content -Path "merlin_dnsmasq_best_output.txt" -Value ($dnsMasqContent + "`r`n") -Encoding UTF8 -NoNewline
    Set-Content -Path "openwrt_dnsmasq_best_output.txt" -Value ($dnsMasqContent + "`r`n") -Encoding UTF8 -NoNewline
}

function Main {
    if ($Jobs -lt 1) {
        Write-Error "-Jobs 必须是大于 0 的整数。"
        exit 1
    }

    if (-not (Test-CommandExists -Command $CurlPath)) {
        Write-Error "未找到 curl.exe，请先安装 curl，或通过 -CurlPath 指定 curl.exe 路径。"
        exit 1
    }

    if (-not (Test-Path -Path $ConfigPath -PathType Leaf)) {
        Write-Error "未找到配置文件：$ConfigPath"
        exit 1
    }

    Write-Host "***************  Xbox CDN SpeedTest *****************"
    Write-Host "** Finding your best CDN for Xbox Game Downloads ****"

    # 使用 HashSet 去重，同时用数组保留原始顺序，避免重复 IP 浪费测速时间。
    $seenIps = New-Object "System.Collections.Generic.HashSet[string]"
    $cdnIps = New-Object "System.Collections.Generic.List[string]"

    foreach ($line in Get-Content -Path $ConfigPath -Encoding UTF8) {
        $ipAddress = ConvertTo-TrimmedLine -Line $line
        if ($ipAddress.Contains(".") -and $seenIps.Add($ipAddress)) {
            [void]$cdnIps.Add($ipAddress)
        }
    }

    $allCount = $cdnIps.Count
    if ($allCount -eq 0) {
        Write-Host "[LOG]All CDN Failed, Bye Bye!"
        exit 0
    }

    $bestIp = ""
    $bestSpeed = 0
    $runningJobs = @()
    $results = @()

    function Receive-SpeedJobResult {
        param(
            [Parameter(Mandatory = $true)]
            [object]$FinishedJob
        )

        $jobResult = Receive-Job -Job $FinishedJob
        Remove-Job -Job $FinishedJob
        if ($null -ne $jobResult) {
            Write-Host ("[TEST {0}/{1}] [Address: {2}] ....... {3}KB/s " -f `
                $jobResult.Index, `
                $jobResult.AllCount, `
                $jobResult.IpAddress, `
                $jobResult.SpeedKb)
        }

        return $jobResult
    }

    for ($ipIndex = 0; $ipIndex -lt $cdnIps.Count; $ipIndex += 1) {
        while ($runningJobs.Count -ge $Jobs) {
            $finishedJob = Wait-Job -Job $runningJobs -Any
            $results += Receive-SpeedJobResult -FinishedJob $finishedJob
            $runningJobs = @($runningJobs | Where-Object { $_.Id -ne $finishedJob.Id })
        }

        $runningJobs += Start-CdnSpeedJob `
            -Index ($ipIndex + 1) `
            -AllCount $allCount `
            -IpAddress $cdnIps[$ipIndex]
    }

    while ($runningJobs.Count -gt 0) {
        $finishedJob = Wait-Job -Job $runningJobs -Any
        $results += Receive-SpeedJobResult -FinishedJob $finishedJob
        $runningJobs = @($runningJobs | Where-Object { $_.Id -ne $finishedJob.Id })
    }

    foreach ($result in ($results | Sort-Object -Property Index)) {
        if ($result.SpeedKb -gt $bestSpeed) {
            $bestSpeed = $result.SpeedKb
            $bestIp = $result.IpAddress
        }
    }

    Write-Host "[LOG]All CDN Test complete. Have fun!"
    if (($bestIp -ne "") -and ($bestSpeed -gt 0)) {
        Write-Host ("[LOG]Your Best CDN is {0}, {1}KB/s!" -f $bestIp, $bestSpeed)
        Write-OutputFiles -BestIp $bestIp
    } else {
        Write-Host "[LOG]All CDN Failed, Bye Bye!"
    }
}

Main
