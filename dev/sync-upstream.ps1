param([switch]$CheckOnly)

$ErrorActionPreference = 'Stop'
$repoPath = Split-Path $PSScriptRoot -Parent
Push-Location -LiteralPath $repoPath
try {
    $branch = git branch --show-current
    if ($branch -ne 'feature/novel-reader') {
        throw '请先切换到产品分支 feature/novel-reader。'
    }
    if (git status --porcelain) {
        throw '工作区有未提交修改，请提交后再同步上游。'
    }
    $remoteUrl = git remote get-url upstream
    if ($remoteUrl -ne 'https://github.com/Predidit/Kazumi.git') {
        throw 'upstream 应指向 https://github.com/Predidit/Kazumi.git。'
    }
    $gitDirectory = git rev-parse --absolute-git-dir
    $logPath = Join-Path $gitDirectory 'book-upstream-sync.log'
    git fetch --quiet upstream main *> $logPath
    if ($LASTEXITCODE -ne 0) {
        Get-Content -LiteralPath $logPath -Tail 20
        throw '拉取上游失败，未进行合并。'
    }
    $newCommits = git rev-list --count HEAD..upstream/main
    Write-Output "上游待合并提交：$newCommits"
    if ($CheckOnly -or $newCommits -eq '0') { return }
    git merge --no-edit upstream/main *> $logPath
    if ($LASTEXITCODE -ne 0) {
        Get-Content -LiteralPath $logPath -Tail 20
        throw '合并尚未完成。请解决 git status 列出的冲突并提交；需要取消时运行 git merge --abort。'
    }
    Write-Output '上游已合并到产品分支。请检查产品名称、应用标识和更新地址，运行测试后推送以触发构建。'
} finally {
    Pop-Location
}
