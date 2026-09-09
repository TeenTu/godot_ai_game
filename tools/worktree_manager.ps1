[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'doctor', 'lock', 'unlock', 'acquire', 'release', 'create', 'remove', 'repair', 'prune', 'help')]
    [string]$Command = 'status',

    [string]$Name,
    [string]$Owner = $env:USERNAME,
    [string]$Reason = 'Permanent project worktree',
    [switch]$ConfirmAction
)

$ErrorActionPreference = 'Stop'

function Get-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $CanonicalRepo $Path))
}

function Normalize-Path {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FullPath $Path).TrimEnd([char[]]@('\', '/'))
}

function Test-SamePath {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    return [System.StringComparer]::OrdinalIgnoreCase.Equals((Normalize-Path $Left), (Normalize-Path $Right))
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $output = @(& git -C $WorkingDirectory @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $rendered = ($output | ForEach-Object { $_.ToString() }) -join "`n"
        throw "git $($Arguments -join ' ') failed in $WorkingDirectory`n$rendered"
    }
    return $output
}

function Invoke-WithManagerLock {
    param([Parameter(Mandatory = $true)][scriptblock]$Action)

    $mutexName = [string]$Registry.manager.mutex
    $mutexName = $mutexName -replace '/', '\'
    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    $hasLock = $false
    try {
        try {
            $hasLock = $mutex.WaitOne(0)
        } catch [System.Threading.AbandonedMutexException] {
            $hasLock = $true
        }
        if (-not $hasLock) {
            throw "另一个 worktree 管理操作正在执行。请等待它结束，不要绕过管理器直接操作 .git/worktrees。"
        }
        & $Action
    } finally {
        if ($hasLock) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

function Get-RegistryEntries {
    return @($Registry.worktrees | Where-Object { $_.lifecycle -ne 'retired' })
}

function Get-AllRegistryEntries {
    return @($Registry.worktrees)
}

function Get-Entry {
    param([Parameter(Mandatory = $true)][string]$EntryName)

    $entry = Get-AllRegistryEntries | Where-Object { $_.name -eq $EntryName }
    if ($null -eq $entry) {
        throw "注册表中不存在 worktree '$EntryName'。请先更新 docs/worktree_registry.json。"
    }
    return $entry
}

function Get-ActualWorktrees {
    $lines = Invoke-Git $CanonicalRepo @('worktree', 'list', '--porcelain')
    $records = New-Object System.Collections.Generic.List[object]
    $current = $null

    foreach ($rawLine in $lines) {
        $line = [string]$rawLine
        if ($line.StartsWith('worktree ')) {
            if ($null -ne $current) {
                $records.Add([PSCustomObject]$current)
            }
            $current = [ordered]@{
                Path = $line.Substring(9).Trim()
                Head = ''
                Branch = ''
                Locked = $false
                LockReason = ''
                Prunable = $false
                PrunableReason = ''
            }
        } elseif ($null -ne $current -and $line.StartsWith('HEAD ')) {
            $current.Head = $line.Substring(5).Trim()
        } elseif ($null -ne $current -and $line.StartsWith('branch ')) {
            $ref = $line.Substring(7).Trim()
            if ($ref.StartsWith('refs/heads/')) {
                $current.Branch = $ref.Substring(11)
            } else {
                $current.Branch = $ref
            }
        } elseif ($null -ne $current -and $line -eq 'detached') {
            $current.Branch = '(detached)'
        } elseif ($null -ne $current -and ($line -eq 'locked' -or $line.StartsWith('locked '))) {
            $current.Locked = $true
            if ($line.Length -gt 7) {
                $current.LockReason = $line.Substring(7).Trim()
            }
        } elseif ($null -ne $current -and ($line -eq 'prunable' -or $line.StartsWith('prunable '))) {
            $current.Prunable = $true
            if ($line.Length -gt 9) {
                $current.PrunableReason = $line.Substring(9).Trim()
            }
        }
    }
    if ($null -ne $current) {
        $records.Add([PSCustomObject]$current)
    }
    return $records.ToArray()
}

function Find-ActualForEntry {
    param([Parameter(Mandatory = $true)]$Entry)

    $expectedPath = Get-FullPath ([string]$Entry.path)
    return Get-ActualWorktrees | Where-Object { Test-SamePath $_.Path $expectedPath }
}

function Get-LeaseState {
    if (-not (Test-Path -LiteralPath $LeasePath)) {
        return @()
    }
    $state = Get-Content -LiteralPath $LeasePath -Raw | ConvertFrom-Json
    if ($null -eq $state.leases) {
        return @()
    }
    return @($state.leases)
}

function Save-LeaseState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Leases)

    $stateDir = Split-Path -Parent $LeasePath
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    $payload = [ordered]@{
        schema_version = 1
        leases = @($Leases)
    }
    $payload | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $LeasePath -Encoding UTF8
}

function Save-Registry {
    $Registry | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $RegistryPath -Encoding UTF8
}

function Require-Name {
    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw "该命令需要 -Name，例如 -Name boom。"
    }
}

function Show-Status {
    $actual = Get-ActualWorktrees
    $leases = Get-LeaseState
    $rows = foreach ($entry in Get-RegistryEntries) {
        $actualEntry = $actual | Where-Object { Test-SamePath $_.Path (Get-FullPath ([string]$entry.path)) }
        $lease = $leases | Where-Object { $_.name -eq $entry.name }
        $dirtyCount = 0
        if ($null -ne $actualEntry -and (Test-Path -LiteralPath $actualEntry.Path)) {
            $dirtyCount = @(git -C $actualEntry.Path status --porcelain 2>$null).Count
        }
        [PSCustomObject]@{
            Name = $entry.name
            Branch = $entry.branch
            Actual = if ($null -eq $actualEntry) { 'MISSING' } else { 'OK' }
            Locked = if ($null -eq $actualEntry) { '-' } elseif ($actualEntry.Locked) { 'YES' } else { 'NO' }
            Changes = $dirtyCount
            Lease = if ($null -eq $lease) { '-' } else { [string]$lease.owner }
        }
    }
    $rows | Format-Table -AutoSize
}

function Invoke-Doctor {
    $failures = New-Object System.Collections.Generic.List[string]
    $entries = Get-RegistryEntries
    $actual = Get-ActualWorktrees

    $duplicateNames = @($entries | Group-Object name | Where-Object Count -gt 1)
    foreach ($duplicate in $duplicateNames) {
        $failures.Add("注册表存在重复 name: $($duplicate.Name)")
    }
    $duplicateBranches = @($entries | Group-Object branch | Where-Object Count -gt 1)
    foreach ($duplicate in $duplicateBranches) {
        $failures.Add("注册表存在重复 branch: $($duplicate.Name)")
    }

    foreach ($entry in $entries) {
        $actualEntry = $actual | Where-Object { Test-SamePath $_.Path (Get-FullPath ([string]$entry.path)) }
        if ($null -eq $actualEntry) {
            $failures.Add("缺少 worktree: $($entry.name) -> $($entry.path)")
            continue
        }
        if ($actualEntry.Branch -ne [string]$entry.branch) {
            $failures.Add("分支不匹配: $($entry.name)，期望 $($entry.branch)，实际 $($actualEntry.Branch)")
        }
        if ([bool]$entry.protected -and -not $actualEntry.Locked) {
            $failures.Add("长期 worktree 未锁定: $($entry.name)")
        }
        if ($actualEntry.Prunable) {
            $failures.Add("worktree 被 Git 标记为可 prune: $($entry.name) ($($actualEntry.PrunableReason))")
        }
    }

    foreach ($item in $actual) {
        $known = Get-AllRegistryEntries | Where-Object { Test-SamePath $_.path $item.Path }
        if ($null -eq $known) {
            $failures.Add("发现未登记 worktree: $($item.Path)")
        }
    }

    foreach ($retired in (Get-AllRegistryEntries | Where-Object { $_.lifecycle -eq 'retired' })) {
        if ($null -ne (Find-ActualForEntry $retired)) {
            $failures.Add("已 retired 的 worktree 仍被 Git 登记: $($retired.name)")
        }
    }

    foreach ($lease in Get-LeaseState) {
        $known = $entries | Where-Object { $_.name -eq $lease.name }
        if ($null -eq $known) {
            $failures.Add("租约指向未登记 worktree: $($lease.name)")
        }
    }

    if ($failures.Count -eq 0) {
        Write-Host 'WORKTREE_DOCTOR result=PASS'
        return $true
    }

    Write-Host 'WORKTREE_DOCTOR result=FAIL'
    foreach ($failure in $failures) {
        Write-Host "- $failure"
    }
    return $false
}

function Lock-Entry {
    Require-Name
    $entry = Get-Entry $Name
    if ($entry.name -eq 'main') {
        throw 'main 是主 worktree，不需要也不能通过此命令锁定。'
    }
    $actualEntry = Find-ActualForEntry $entry
    if ($null -eq $actualEntry) {
        throw "worktree 不存在或未被 Git 识别: $($entry.path)"
    }
    if ($actualEntry.Branch -ne [string]$entry.branch) {
        throw "分支不匹配，拒绝锁定。期望 $($entry.branch)，实际 $($actualEntry.Branch)"
    }
    if ($actualEntry.Locked) {
        Write-Host "$Name already locked"
        return
    }
    $null = Invoke-Git $CanonicalRepo @('worktree', 'lock', '--reason', $Reason, (Get-FullPath ([string]$entry.path)))
    Write-Host "LOCKED $Name"
}

function Unlock-Entry {
    Require-Name
    $entry = Get-Entry $Name
    if ($entry.name -eq 'main') {
        throw 'main 是主 worktree，不需要解锁。'
    }
    $actualEntry = Find-ActualForEntry $entry
    if ($null -eq $actualEntry) {
        throw "worktree 不存在或未被 Git 识别: $($entry.path)"
    }
    if (-not $actualEntry.Locked) {
        Write-Host "$Name already unlocked"
        return
    }
    $null = Invoke-Git $CanonicalRepo @('worktree', 'unlock', (Get-FullPath ([string]$entry.path)))
    Write-Host "UNLOCKED $Name"
}

function Acquire-Lease {
    Require-Name
    $entry = Get-Entry $Name
    if ($entry.name -eq 'main') {
        throw 'main 不允许分配给游戏 Agent。'
    }
    $actualEntry = Find-ActualForEntry $entry
    if ($null -eq $actualEntry) {
        throw "不能给不存在的 worktree 分配租约: $Name"
    }
    $leases = @(Get-LeaseState)
    if ($null -ne ($leases | Where-Object { $_.name -eq $Name })) {
        throw "worktree '$Name' 已有租约。先确认原 Agent 已结束，再执行 release。"
    }
    if ([string]::IsNullOrWhiteSpace($Owner)) {
        $Owner = 'unknown'
    }
    $leases += [PSCustomObject]@{
        name = $Name
        owner = $Owner
        acquired_utc = [DateTime]::UtcNow.ToString('o')
        manager_pid = $PID
    }
    Save-LeaseState $leases
    Write-Host "ACQUIRED $Name owner=$Owner"
}

function Release-Lease {
    Require-Name
    $leases = @(Get-LeaseState)
    $remaining = @($leases | Where-Object { $_.name -ne $Name })
    if ($remaining.Count -eq $leases.Count) {
        Write-Host "$Name has no lease"
        return
    }
    Save-LeaseState $remaining
    Write-Host "RELEASED $Name"
}

function Create-Entry {
    Require-Name
    $entry = Get-Entry $Name
    if ($entry.lifecycle -eq 'retired') {
        throw "worktree '$Name' 已 retired。先在注册表中恢复 lifecycle 后再 create。"
    }
    $path = Get-FullPath ([string]$entry.path)
    $actualEntry = Find-ActualForEntry $entry
    if ($null -ne $actualEntry) {
        if ($actualEntry.Branch -ne [string]$entry.branch) {
            throw "路径已被 Git 登记但分支不匹配: $Name"
        }
        Write-Host "$Name already exists"
        return
    }
    if (Test-Path -LiteralPath $path) {
        throw "目标路径已存在但不是 Git worktree，拒绝覆盖: $path"
    }
    $null = Invoke-Git $CanonicalRepo @('show-ref', '--verify', '--quiet', "refs/heads/$($entry.branch)")
    $null = Invoke-Git $CanonicalRepo @('worktree', 'add', $path, [string]$entry.branch)
    if ([bool]$entry.protected) {
        $null = Invoke-Git $CanonicalRepo @('worktree', 'lock', '--reason', "Permanent $($entry.name) development worktree", $path)
    }
    Write-Host "CREATED $Name"
}

function Remove-Entry {
    Require-Name
    if (-not $ConfirmAction) {
        throw 'remove 会删除 worktree 工作目录，请加 -ConfirmAction。'
    }
    $entry = Get-Entry $Name
    if ($entry.name -eq 'main') {
        throw '禁止删除 main worktree。'
    }
    $leases = Get-LeaseState
    if ($null -ne ($leases | Where-Object { $_.name -eq $Name })) {
        throw "worktree '$Name' 仍有租约，先确认 Agent 已结束并 release。"
    }
    $actualEntry = Find-ActualForEntry $entry
    if ($null -eq $actualEntry) {
        if ($entry.lifecycle -eq 'retired') {
            Write-Host "$Name already removed"
            return
        }
        throw "worktree 不存在或未被 Git 识别: $($entry.path)"
    }
    $dirty = @(git -C $actualEntry.Path status --porcelain 2>$null)
    if ($dirty.Count -gt 0) {
        throw "worktree '$Name' 有未提交改动，拒绝删除。"
    }
    $upstream = @(& git -C $actualEntry.Path rev-parse --abbrev-ref '@{upstream}' 2>$null)
    if ($LASTEXITCODE -ne 0 -or $upstream.Count -eq 0) {
        throw "worktree '$Name' 没有可验证的 upstream，拒绝删除。"
    }
    $counts = @(& git -C $actualEntry.Path rev-list --left-right --count "$($upstream[0].Trim())...$($entry.branch)" 2>$null)
    if ($LASTEXITCODE -ne 0 -or $counts.Count -eq 0) {
        throw "无法验证 worktree '$Name' 是否有未 push 提交，拒绝删除。"
    }
    $parts = ([string]$counts[0]).Trim() -split '\s+'
    if ($parts.Count -lt 2 -or [int]$parts[1] -gt 0) {
        throw "worktree '$Name' 有未 push 提交，拒绝删除。"
    }
    $null = Invoke-Git $CanonicalRepo @('worktree', 'remove', $actualEntry.Path)
    $entry.lifecycle = 'retired'
    Save-Registry
    Write-Host "REMOVED $Name and marked retired"
}

function Repair-Entry {
    Require-Name
    if (-not $ConfirmAction) {
        throw 'repair 会修改 Git worktree 元数据，请加 -ConfirmAction。'
    }
    $entry = Get-Entry $Name
    $path = Get-FullPath ([string]$entry.path)
    if (-not (Test-Path -LiteralPath $path)) {
        throw "路径不存在，拒绝 repair: $path"
    }
    $null = Invoke-Git $CanonicalRepo @('worktree', 'repair', $path)
    Write-Host "REPAIRED $Name"
}

function Prune-Worktrees {
    if (-not $ConfirmAction) {
        $preview = @(Invoke-Git $CanonicalRepo @('worktree', 'prune', '--dry-run', '--verbose'))
        if ($preview.Count -eq 0) {
            Write-Host 'PRUNE_PREVIEW empty'
        } else {
            Write-Host 'PRUNE_PREVIEW'
            $preview | ForEach-Object { Write-Host $_ }
        }
        throw '默认只预览，不执行 prune。确认无误后加 -ConfirmAction。'
    }
    if ((Get-LeaseState).Count -gt 0) {
        throw '存在活跃租约，拒绝 prune。先 release 并确认 Agent 已退出。'
    }
    $null = Invoke-DoctorForPrune
    $null = Invoke-Git $CanonicalRepo @('worktree', 'prune', '--verbose')
    Write-Host 'PRUNE_DONE'
}

function Invoke-DoctorForPrune {
    $actual = Get-ActualWorktrees
    foreach ($entry in Get-RegistryEntries) {
        if ($null -eq (Find-ActualForEntry $entry)) {
            throw "注册表中的长期 worktree 不完整，拒绝 prune: $($entry.name)"
        }
    }
    foreach ($retired in (Get-AllRegistryEntries | Where-Object { $_.lifecycle -eq 'retired' })) {
        if ($null -ne (Find-ActualForEntry $retired)) {
            throw "retired worktree 仍存在，拒绝 prune: $($retired.name)"
        }
    }
    return $true
}

function Show-Help {
    @'
唯一 worktree 管理入口：
  status                         查看注册表与实际 worktree 状态
  doctor                         检查路径、分支、锁、孤儿 worktree、租约
  lock   -Name boom              锁定长期 worktree，防止 prune
  unlock -Name boom              解锁（仅维护/迁移时使用）
  acquire -Name boom             分配 Agent 租约
  release -Name boom             释放 Agent 租约
  create -Name <name>            按注册表创建 worktree
  remove -Name <name> -ConfirmAction
  repair -Name boom -ConfirmAction
  prune                          只预览，不执行清理
  prune -ConfirmAction           通过安全检查后执行清理

禁止直接删除 .git/worktrees/*，禁止绕过本管理器执行 worktree prune/remove。
'@ | Write-Host
}

try {
    $scriptRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $registryPath = Join-Path $scriptRoot 'docs/worktree_registry.json'
    if (-not (Test-Path -LiteralPath $registryPath)) {
        throw "找不到注册表: $registryPath"
    }
    $Registry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json
    $CanonicalRepo = (Resolve-Path (Get-FullPath ([string]$Registry.repository))).Path
    $gitCommonRaw = (& git -C $CanonicalRepo rev-parse --git-common-dir 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "无法解析 Git common dir: $($gitCommonRaw -join "`n")"
    }
    if ([System.IO.Path]::IsPathRooted([string]$gitCommonRaw)) {
        $GitCommonDir = [System.IO.Path]::GetFullPath(([string]$gitCommonRaw).Trim())
    } else {
        $GitCommonDir = [System.IO.Path]::GetFullPath((Join-Path $CanonicalRepo ([string]$gitCommonRaw).Trim()))
    }
    $LeasePath = Join-Path $GitCommonDir 'worktree-manager/leases.json'

    switch ($Command) {
        'status' { Show-Status }
        'doctor' { if (-not (Invoke-Doctor)) { exit 2 } }
        'lock' { Invoke-WithManagerLock { Lock-Entry } }
        'unlock' { Invoke-WithManagerLock { Unlock-Entry } }
        'acquire' { Invoke-WithManagerLock { Acquire-Lease } }
        'release' { Invoke-WithManagerLock { Release-Lease } }
        'create' { Invoke-WithManagerLock { Create-Entry } }
        'remove' { Invoke-WithManagerLock { Remove-Entry } }
        'repair' { Invoke-WithManagerLock { Repair-Entry } }
        'prune' { Invoke-WithManagerLock { Prune-Worktrees } }
        'help' { Show-Help }
    }
} catch {
    [Console]::Error.WriteLine(('worktree_manager error: ' + [string]$_.Exception.Message))
    exit 1
}
