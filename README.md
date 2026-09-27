# sing-box 多协议安装脚本（个人修改版）

基于 [eooce/sing-box](https://github.com/eooce/sing-box) 修改。

**当前版本: v2.5.18**

## 协议

| 类型 | 协议 |
|------|------|
| 直连 | vless-reality · hysteria2 · tuic · vless-ws（无 TLS） |
| Argo | vmess-ws · vless-ws · trojan-ws |
| 可选 | anytls · socks5 · shadowsocks-2022 |

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/gxjxzgx/sing-box/main/sb.sh)
```

或下载后执行：

```bash
curl -fsSL -o sb.sh https://raw.githubusercontent.com/gxjxzgx/sing-box/main/sb.sh
bash sb.sh
```

## 常用参数

```bash
bash sb.sh -i          # 安装
bash sb.sh -i --force  # 强制重装
bash sb.sh -c          # 查看节点 / 订阅链接
bash sb.sh -u          # 卸载
bash sb.sh -h          # 帮助
```

## 主要改动摘要

- vless-ws 直连无 TLS
- 独立订阅端口 `SUB_PORT` + Argo 路径 `/s/<token>`
- 主菜单：5 查看节点与订阅；7 管理订阅（开关 / 改端口 / 新链接 / Nginx）
- 小磁盘优先镜像下载，官方包管道解压
- 端口误报统一判定；IPv6 改端口 / 切 IP 同步 `host=`
- 菜单排版统一

## 文件说明

| 文件 | 说明 |
|------|------|
| `sb.sh` | **推荐** 最新安装脚本（v2.5.18） |
| `sing-box2.sh` | 历史版本备份 |
| `sing-box-argo` | Argo 相关旧脚本 |
| `sing-box` | 历史文件 |

## 注意

仅供学习交流。请遵守当地法律法规与服务器提供商条款。
