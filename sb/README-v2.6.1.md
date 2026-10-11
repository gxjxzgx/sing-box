# sing-box 多协议安装脚本 — 模块化 v2.6.1

由单文件 `sb.sh`（v2.6.1，约 5200 行）按功能拆分。

## 使用

```bash
# 保持目录结构，在 root 下执行入口
chmod +x sb-v2.6.1.sh
sudo bash sb-v2.6.1.sh          # 交互菜单
sudo bash sb-v2.6.1.sh -i       # 无交互安装
sudo bash sb-v2.6.1.sh -c       # 查看节点
sudo bash sb-v2.6.1.sh -h       # 帮助
```

**要求：`sb-v2.6.1.sh` 与 `lib/` 必须在同一目录。**

## 模块一览

| 文件 | 职责 |
|------|------|
| `sb-v2.6.1.sh` | 入口：按顺序 source 全部 lib，再进菜单/参数解析 |
| `lib/common.sh` | 颜色、常量、`b64_decode`、`update_all_vmess`、Alpine bash、Token 清理 |
| `lib/port.sh` | 端口真实占用检测、`check_singbox/argo/nginx` |
| `lib/system.sh` | 包管理、IP/ISP、节点前缀、订阅令牌、`safe_apply_conf` |
| `lib/firewall.sh` | `allow_port` |
| `lib/install.sh` | `install_singbox`（下载、端口、配置生成） |
| `lib/argo.sh` | 固定/临时隧道、`rewrite_argo_service`、systemd/OpenRC |
| `lib/nodes.sh` | `get_info` 写节点与订阅 |
| `lib/nginx.sh` | Argo 路径分流、订阅 conf、启停、卸载、快捷方式 |
| `lib/telegram.sh` | TG 推送、监控、自动安装路径 |
| `lib/config.sh` | 改端口/UUID/SNI/前缀/IPv4·IPv6 等 |
| `lib/manage.sh` | sing-box / Argo / 订阅 / Nginx 管理菜单 |
| `lib/warp.sh` | WARP 与 Socks/HTTP 分流 |
| `lib/protocols.sh` | Socks5 / VLESS-WS 直连 / SS2022 增删 |
| `lib/menu_entry.sh` | 主菜单与 `-i/-u/-c/-r/-h` |

## 本版修复

见 `CHANGELOG-fix.md`。

## 与单文件关系

- 逻辑与 `sb.sh` v2.6.1 **等价**（按行段拆分，未改业务逻辑）。
- 若需单文件分发，仍用仓库根目录完整 `sb.sh`，或自行 `cat lib/*.sh` 合并（注意顺序与入口包装）。

## 合并回单文件（可选）

```bash
# 仅示意：顺序需与 sb-v2.6.1.sh 中 source 列表一致，并去掉本入口的 source 循环
cat lib/common.sh lib/port.sh lib/system.sh lib/firewall.sh \
    lib/install.sh lib/argo.sh lib/nodes.sh lib/nginx.sh \
    lib/telegram.sh lib/config.sh lib/manage.sh lib/warp.sh \
    lib/protocols.sh lib/menu_entry.sh > sb-merged-v2.6.1.sh
```
