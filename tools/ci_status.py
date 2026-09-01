#!/usr/bin/env python3
"""GitHub Actions 状态/日志查询小工具。

解决"助理拿不到 CI 信息、需要认证"的问题：
token 从本机 Git Credential Manager 里取（git credential fill），
不依赖 gh CLI、不依赖环境变量，curl/WebFetch 直接可用。

用法:
    python tools/ci_status.py                 # 列出最近 5 次运行
    python tools/ci_status.py <run_id>        # 查看某次运行的每个步骤结论
    python tools/ci_status.py <run_id> --logs # 下载该次运行的全部日志 zip
"""
import json
import os
import subprocess
import sys
import urllib.request

REPO = "TeenTu/godot_ai_game"
API = "https://api.github.com"


def get_token() -> str:
    """从 Git Credential Manager 取 github.com 的凭据 token。"""
    inp = "protocol=https\nhost=github.com\n\n"
    out = subprocess.run(
        ["git", "credential", "fill"], input=inp, capture_output=True, text=True
    ).stdout
    for line in out.splitlines():
        if line.startswith("password="):
            return line.split("=", 1)[1]
    raise SystemExit("无法从 Git Credential Manager 获取 GitHub token")


def api(path: str, token: str) -> dict:
    req = urllib.request.Request(
        f"{API}{path}", headers={"Authorization": f"Bearer {token}", "User-Agent": "ci-status"}
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def list_runs(token: str, n: int = 5) -> None:
    d = api(f"/repos/{REPO}/actions/runs?per_page={n}", token)
    print(f"{'RUN_ID':<12}{'STATUS':<10}{'CONCLUSION':<10}{'BRANCH':<16}标题")
    for r in d.get("workflow_runs", []):
        print(
            f"{r['id']:<12}{r['status']:<10}{str(r['conclusion']):<10}"
            f"{r['head_branch']:<16}{r['display_title'][:45]}"
        )


def show_run(run_id: str, token: str) -> None:
    d = api(f"/repos/{REPO}/actions/runs/{run_id}/jobs", token)
    for j in d.get("jobs", []):
        print(f"\n=== {j['name']} -> {j['conclusion']} ===")
        for s in j.get("steps", []):
            print(f"  [{s['number']:>2}] {s['name']:<45} {s['conclusion']}")


def fetch_logs(run_id: str, token: str) -> None:
    url = f"{API}/repos/{REPO}/actions/runs/{run_id}/logs"
    req = urllib.request.Request(
        url, headers={"Authorization": f"Bearer {token}", "User-Agent": "ci-status"}
    )
    dest = f"ci_{run_id}_logs.zip"
    with urllib.request.urlopen(req, timeout=120) as r, open(dest, "wb") as f:
        f.write(r.read())
    print(f"已保存: {os.path.abspath(dest)}")


if __name__ == "__main__":
    token = get_token()
    args = sys.argv[1:]
    if not args:
        list_runs(token)
    elif args[0] == "--logs" and len(args) > 1:
        fetch_logs(args[1], token)
    else:
        show_run(args[0], token)
