# Realm TCP/UDP Forwarding Panel

在 Linux 上通过同一个菜单创建、查看和迁移 Realm、iptables、nftables 转发规则。每条规则可以选择独立的后端、监听地址、TCP/UDP 协议和目标端口。面板支持单条、批量和按来源后端迁移。

## 安装

需要 root、systemd、Bash、curl、Python 3.8+、tomlkit 和 iproute2。启动器可以通过 apt、dnf 或 pacman 安装 Python 依赖。使用内核转发的主机还需安装对应的 iptables 或 nftables 工具，IPv6 iptables 需要可用的 ip6tables NAT 表。

```bash
git clone https://github.com/Banezzz/Realm-TCP-UDP-Forwarding-Panel.git
cd Realm-TCP-UDP-Forwarding-Panel
sudo ./realm.sh
```

原有的单文件安装方式也可使用。启动器会获取配套的 `panel.py`，按内置 SHA-256 校验。使用分支、标签或离线副本时，请将同一提交的两个文件放在同一目录。

```bash
curl -fLO https://raw.githubusercontent.com/Banezzz/Realm-TCP-UDP-Forwarding-Panel/main/realm.sh
sudo bash realm.sh
```

菜单 1 从官方 Releases API 选择适配架构的最新 **完整版** Realm，校验资产摘要及真实可执行版本。x86_64、aarch64 和 armv7 硬浮点优先选择 musl 版本。已验证的版本为 **v2.9.6**，也可运行 `sudo ./realm.sh install v2.9.6` 固定本次安装版本。更新查询失败会保留当前版本。菜单 11 可配置资产下载反代，版本元数据和摘要来自官方 API。`--no-update` 跳过面板更新检查，`--no-proxy` 使用直连。[上游发布说明](https://github.com/zhboner/realm/releases/tag/v2.9.6)

## 创建转发时怎样选后端

| 后端 | 适合的场景 | 使用条件与取舍 |
| --- | --- | --- |
| Realm | 动态域名、IPv4 与 IPv6 跨族、多后端、PROXY protocol、TLS/WS 或 MPTCP | 占用用户态进程及监听端口。应用 Realm 配置可能重启服务并断开现有连接。MPTCP 需要内核、对端及路径配置支持。 |
| iptables | 已使用 xtables 工具、只需同族 TCP/UDP 端口转发 | 使用内核 DNAT，按地址族提交。通配监听展开为当前本机地址，地址变更后重新应用。大量规则会增加链的匹配成本。 |
| nftables | 需要原生 nft、IPv4/IPv6 一起更新的 Linux 主机 | 使用独立的 inet 表，每次事务完整替换。需要内核 inet NAT 支持。缺少 FIB 匹配模块时使用本机地址列表。 |

菜单 2 在选择前显示上述取舍。单条创建可选 IPv4、IPv6、双栈或具体监听 IP。批量 CSV 每行一个 endpoint，例如：

```text
8080,192.0.2.10,80,网站,2,tcp
5300,2001:db8::53,53,DNS,3,udp
```

列顺序为本地端口、目标地址、目标端口、备注、监听模式、协议。后三列可省略。模式 1 为双栈，2 为 IPv4，3 为仅 IPv6。协议取 `tcp`、`udp` 或 `both`。

Realm 高级选项接受 endpoint TOML，可设置 `extra_remotes`、`balance`、`through`、进出接口、`listen_transport`、`remote_transport` 和 `network` 字段。下例为三个目标设置 4:2:1 权重，并对该规则启用出站 MPTCP。PROXY protocol 要求对应的一端配置接收或发送。[上游配置说明](https://github.com/zhboner/realm/tree/v2.9.6#configuration)

```toml
extra_remotes = ["192.0.2.11:443", "192.0.2.12:443"]
balance = "roundrobin: 4, 2, 1"
network.send_mptcp = true
```

## 一键迁移与恢复

菜单 15 选择来源规则及目标后端，预览并确认一次。来源支持序号、范围、逗号列表、后端名称或 `all`。三种后端可以同时承载不同规则。下列命令均从仓库目录执行。

```bash
sudo ./realm.sh list
sudo ./realm.sh migrate realm iptables --dry-run
sudo ./realm.sh migrate realm iptables
sudo ./realm.sh migrate iptables nftables
sudo ./realm.sh migrate 1,3-5 realm
```

同一条命令加 `--yes` 可以直接应用。迁移会保留监听、目标、协议、备注和原始 Realm 配置。若选中的规则带有 NAT 无法承载的传输、负载均衡或专用网络参数，面板会列出相关字段并终止这批变更。用户可仅选择兼容规则。双栈 Realm 可将两类来流都转给单族目标，NAT 只能处理同族流量；预览会显示可用地址族、实际目标 IP 和缺失的地址族。仅监听的地址族完全没有目标时，整批变更终止。

两种 NAT 后端处理从网络接口进入本机地址的连接。它们使用系统 DNS，在应用时为每个地址族选择一个目标 IP。菜单 14 或 `sudo ./realm.sh apply` 重新解析域名并应用。开机恢复上次成功提交的目标 IP。主机的 FORWARD 策略、安全组和路由需要允许转发流量。nftables 使用专用表 `inet realm_panel` 和连接标记位 `0x40000000`，部署前需确认该位可供面板使用；iptables 使用 NAT 表的 `RFP_PRE`、`RFP_POST` 两条链。

跨后端迁移会影响既有连接。Realm 服务重启会关闭该进程的连接，已有 NAT 会话可能继续使用旧的 conntrack 映射。面板对新配置加锁并预检内核规则，验证 Realm 的实际监听。应用失败时恢复原配置、受管规则和服务状态；若进程意外中断，下一次打开面板会读取事务记录进行恢复。

## 从 0.4.0 升级、备份与导入

首次运行从 `/root/realm/config.toml` 和 `/root/iptables-forward/rules.conf` 读取既有配置。`list` 可先检查规则。首次确认应用后接管旧版专用链，并停用已识别的旧开机服务。旧版写入的全局 MASQUERADE 和系统 IP forwarding 设置可能被其他程序共用，升级时请核对其用途。后续网络转发状态由 `realm-panel-nat.service` 恢复。

```bash
sudo ./realm.sh export /root/forwarding-backup.toml
sudo ./realm.sh import /root/forwarding-backup.toml --dry-run
sudo ./realm.sh import /root/forwarding-backup.toml
sudo ./realm.sh import /root/realm/previous.toml
```

面板完整配置存放在 `/root/realm/panel.toml`，上次变更前的配置在 `previous.toml`。导入会替换全部受管规则，支持旧 Realm TOML、完整面板 TOML 以及菜单中的 Base64 备份。TLS 证书、私钥和网络接口等主机资源需在目标机器上准备。`/root/realm/config.toml` 是为 Realm 生成的运行配置；外部修改会在下一次变更时提示。面板保留定时重启、日志、DNS 设置和卸载入口。

## 验证

```bash
bash -n realm.sh
python3 -m unittest discover -s tests -v
sudo /usr/bin/python3 tests/netns.py /root/realm/realm
sudo env RFP_TEST_AF=6 /usr/bin/python3 tests/netns.py /root/realm/realm
```

网络测试在临时 network namespace 中启动真实 Realm 和 TCP/UDP 回显服务，覆盖全部六个迁移方向、NAT 开机规则重放和故障回滚。需要 iproute2、iptables、nftables、util-linux 及支持对应地址族的内核。测试用进程适配器管理 Realm 生命周期。CI 另在 systemd 环境下检查安装、服务启动和规则恢复。

## 致谢与许可证

转发核心来自 [Realm](https://github.com/zhboner/realm)，原始脚本项目为 EZrealm。面板沿用 MIT License。
