# v2.6.1-fix 修复说明

## 修复：修改隧道/Argo 域名后直连节点丢失
- `lib/manage.sh` `change_argo_domain`：
  - 改为逐行处理，仅改写 vmess / vless-argo / trojan-argo 三类行，其余行原样保留
  - 先写临时文件再原子替换 `url.txt`；改前自动备份为 `url.txt.bak`
  - 改后校验直连行数，若减少（或原文件无直连行）则从 `direct_nodes.cache` 补回
  - vmess 解码/更新失败时原样保留该行，不再丢弃
- `lib/system.sh`：新增 `save_direct_cache` / `restore_direct_cache`，缓存文件 `/etc/sing-box/direct_nodes.cache`
- `lib/nodes.sh` `get_info`：
  - `extra_lines` 过滤规则修正：此前剔除了所有 `vless://`，导致 VLESS-WS 直连在重新生成时丢失；
    同时未剔除 `anytls://`，会造成重复
  - 写完 url.txt 后刷新直连缓存

## 节点命名调整
- 命名规则：有自定义前缀 → `自定义-协议`；无自定义 → `服务商-协议`（不再同时输出）
- `get_isp` 只返回服务商名称（如 `Cloudflare`），不再带国家码 / ASN 号，并去掉逗号
- `build_node_prefix`、`get_info`、改前缀菜单、`change_argo_domain` 补建节点统一遵循上述规则
- 开启 HY2 端口跳跃重写的节点行补上 `-hysteria2` 后缀
