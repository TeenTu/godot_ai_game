#!/usr/bin/env python3
"""腾讯文档 MCP 直连工具 —— 不依赖 tencentdocs.py 的 CLI 认证。

背景：WorkBuddy 宿主已为腾讯文档连接器注入票据，但 CLI（tencentdocs.py）
需要 TDOC_OAUTH_ACCESS_TOKEN 环境变量；其 V2 Gateway credential provider
可能返回 401。本脚本直接从 CODEBUDDY_MCP_CONFIG 读 tencent-docs server 的
url + headers，走 MCP JSON-RPC tools/call 调用，与宿主注入的票据完全一致，
因此无需任何额外认证。

用法:
  tc_doc.py get_user_info
  tc_doc.py upload_image <png_path> [file_name]        # 上传图片 → image_id
  tc_doc.py create_doc <title> <content_md_path> [--format markdown|mdx]
  tc_doc.py get_content <file_id>
  tc_doc.py read <file_id>                              # 返回 MDX 结构（可能截断）
  tc_doc.py find <file_id> <query>                      # 定位块 → block id
  tc_doc.py insert_after <file_id> <anchor_id> <content_md_path>   # MDX 内容
  tc_doc.py delete <file_id> <block_id>
  tc_doc.py list_pages <file_id>

所有输出写 stdout（JSON），失败退出码非 0。
"""
import json
import os
import subprocess
import sys
import urllib.request
import uuid

SERVER_KEY = "tencent-docs"  # CODEBUDDY_MCP_CONFIG 里的 server 条目名


def _load_server():
    raw = os.environ.get("CODEBUDDY_MCP_CONFIG")
    if not raw:
        sys.exit("ERROR: 缺少 CODEBUDDY_MCP_CONFIG 环境变量")
    cfg = json.loads(raw)
    servers = cfg.get("mcpServers") or {}
    server = servers.get(SERVER_KEY)
    if not server:
        sys.exit(f"ERROR: mcpServers 里没有 {SERVER_KEY} 条目")
    return server["url"], dict(server["headers"])


def rpc(url, headers, method, params, retries=3):
    import time
    headers = {**headers, "Content-Type": "application/json"}
    for i in range(retries):
        try:
            body = json.dumps({
                "jsonrpc": "2.0",
                "id": str(uuid.uuid4()),
                "method": method,
                "params": params,
            }).encode()
            req = urllib.request.Request(url, data=body, headers=headers, method="POST")
            with urllib.request.urlopen(req, timeout=60) as resp:
                return json.loads(resp.read().decode())
        except Exception as e:
            if i == retries - 1:
                sys.exit(f"ERROR: {method} 调用失败: {e}")
            time.sleep(0.5)


def call_tool(url, headers, name, arguments):
    # MCP 握手
    try:
        rpc(url, headers, "initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "tc_doc", "version": "1.0"},
        })
    except SystemExit:
        pass
    try:
        rpc(url, headers, "notifications/initialized", {})
    except SystemExit:
        pass
    res = rpc(url, headers, "tools/call", {"name": name, "arguments": arguments})
    if "error" in res and res.get("error"):
        sys.exit(f"ERROR: {name}: {res['error']}")
    content = res.get("result", {}).get("content", [])
    texts = [c.get("text", "") for c in content if c.get("type") == "text"]
    return "\n".join(texts)


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    cmd = sys.argv[1]
    url, headers = _load_server()

    if cmd == "get_user_info":
        print(call_tool(url, headers, "get_user_info", {}))

    elif cmd == "upload_image":
        path, fname = sys.argv[2], (sys.argv[3] if len(sys.argv) > 3 else os.path.basename(path))
        import base64
        b64 = base64.b64encode(open(path, "rb").read()).decode()
        out = call_tool(url, headers, "upload_image", {"file_name": fname, "image_base64": b64})
        data = json.loads(out)
        print(data.get("image_id", out))

    elif cmd == "create_doc":
        title = sys.argv[2]
        content = open(sys.argv[3], encoding="utf-8").read()
        fmt = "markdown"
        if "--format" in sys.argv:
            fmt = sys.argv[sys.argv.index("--format") + 1]
        out = call_tool(url, headers, "create_smartcanvas_by_mdx",
                        {"title": title, "mdx": content, "content_format": fmt})
        print(out)

    elif cmd == "get_content":
        out = call_tool(url, headers, "get_content", {"file_id": sys.argv[2]})
        data = json.loads(out)
        print(data.get("content", out))

    elif cmd == "read":
        out = call_tool(url, headers, "smartcanvas.read", {"file_id": sys.argv[2]})
        print(out)

    elif cmd == "find":
        out = call_tool(url, headers, "smartcanvas.find",
                        {"query": sys.argv[3], "file_id": sys.argv[2]})
        print(out)

    elif cmd == "insert_after":
        file_id, anchor, content_path = sys.argv[2], sys.argv[3], sys.argv[4]
        content = open(content_path, encoding="utf-8").read()
        out = call_tool(url, headers, "smartcanvas.edit",
                        {"file_id": file_id, "action": "INSERT_AFTER", "id": anchor, "content": content})
        print(out)

    elif cmd == "delete":
        out = call_tool(url, headers, "smartcanvas.edit",
                        {"file_id": sys.argv[2], "action": "DELETE", "id": sys.argv[3]})
        print(out)

    elif cmd == "list_pages":
        out = call_tool(url, headers, "smartcanvas.get_top_level_pages", {"file_id": sys.argv[2]})
        print(out)

    else:
        sys.exit(f"未知命令: {cmd}\n\n{__doc__}")


if __name__ == "__main__":
    main()
