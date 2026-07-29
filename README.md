
# Realm TCP/UDP Forwarding Panel

一个功能强大的 **Realm 端口转发管理脚本**，支持一键部署、规则管理、中国网络优化等功能。

---

## 功能特性

- **一键安装**  
  自动检测系统架构，下载最新版 Realm

- **规则管理**
  添加（单条/批量）、查看、删除（单条/批量）端口转发规则

- **双转发引擎**  
  Realm（用户态转发）与 iptables（内核 NAT 转发）两套规则体系并存

- **转发方式互相切换**  
  Realm 规则与 iptables 规则一键互转，自动备份、冲突检测、随时回滚

- **服务控制**  
  启动、停止、重启 Realm 服务

- **定时任务**  
  设置每日自动重启任务

- **自动更新**  
  脚本自动检测并更新到最新版本

- **中国优化**  
  自动检测中国 IP，支持配置 GitHub 反代加速

- **多架构支持**  
  支持 `x86_64`、`aarch64`、`armv7l` 架构

---

## 快速开始

### 一键安装

```bash
wget -N https://raw.githubusercontent.com/Banezzz/Realm-TCP-UDP-Forwarding-Panel/main/realm.sh \
  && chmod +x realm.sh \
  && ./realm.sh
````

### 使用反代安装（中国用户推荐）

```bash
wget -N https://acc.banez.de/https://raw.githubusercontent.com/Banezzz/Realm-TCP-UDP-Forwarding-Panel/main/realm.sh \
  && chmod +x realm.sh \
  && ./realm.sh
```

---

## 系统要求

* Linux 系统（Debian / Ubuntu / CentOS / Fedora / Arch 等）
* Root 权限
* `curl` 和 `wget`（脚本会自动安装）

---

## 功能菜单

```text
1.  安装/更新 Realm
2.  添加转发规则（单条/批量）
3.  查看转发规则
4.  删除转发规则（单条/批量）
5.  启动服务
6.  停止服务
7.  重启服务
8.  定时任务管理
9.  查看日志
10. 完全卸载
11. 代理设置
12. 配置导入导出
13. DNS 解析设置
14. iptables 转发管理
15. 转发方式切换（Realm ⇄ iptables）
0.  退出脚本
```

---

## 转发规则

### 单条添加

交互式逐项输入本地端口、目标地址、目标端口、备注及监听模式。

### 批量添加

每行一条规则，逗号分隔参数，输入空行结束：

```text
本地端口,目标地址,目标端口[,备注][,监听模式]
```

**示例：**
```text
8080,1.2.3.4,80,网站转发,1
9090,example.com,443,域名转发
7070,10.0.0.1,22,,2
```

- 备注和监听模式可省略
- 若需设监听模式但无备注，留空即可：`7070,10.0.0.1,22,,2`
- 输入完成后会显示预览表格，确认后统一写入并重启服务

### 批量删除

支持多种序号格式，删除前预览确认：

```text
3           # 单条
1,3,5       # 多条
23-50       # 范围
1,3,10-20   # 混合
```

### 监听模式

| 模式     | 值  | 地址格式         | 说明                   |
| ------ | -- | ------------ | -------------------- |
| 双栈监听   | 1  | `[::]:端口`    | 同时监听 IPv4 和 IPv6（默认） |
| 仅 IPv4 | 2  | `0.0.0.0:端口` | 仅监听 IPv4             |
| 仅 IPv6 | 3  | `[::]:端口`    | 仅监听 IPv6             |

---

## 两种转发方式

脚本同时支持两套互不干扰的转发引擎，规则各自独立存储：

| | Realm（主菜单 2/3/4） | iptables（主菜单 14） |
| --- | --- | --- |
| 原理 | 用户态进程监听并转发 | 内核 NAT（PREROUTING DNAT + MASQUERADE） |
| 规则文件 | `/root/realm/config.toml` | `/root/iptables-forward/rules.conf` |
| 服务单元 | `realm.service` | `iptables-forward.service` |
| 本机端口占用 | 有（`ss -tlnp` 可见） | 无 |
| 协议控制 | 全局 TCP/UDP 开关（`[network]` 段） | 每条规则可选 TCP / UDP / 两者 |
| 域名目标 | 自动跟随 DNS 变化 | 仅在应用规则时解析一次 |
| 资源开销 | 略高（数据经用户态） | 极低（内核转发） |

> 两者同时对同一端口生效时，iptables 的 DNAT 发生在 PREROUTING，会先于 Realm 的本地监听接管流量。建议同一端口只使用一种方式。

---

## 转发方式切换（主菜单 15）

在 TUI 中通过交互式菜单，把已有规则在两种转发方式之间整体迁移。

```text
[1] Realm 规则迁移到 iptables
[2] iptables 规则迁移到 Realm
[3] 规则对照 / 端口冲突检查
[4] 回滚到切换前状态
[0] 返回主菜单
```

菜单顶部实时显示两侧的服务状态、规则条数与当前正在生效的转发方式。
`iptables 转发管理` 子菜单中的 `[7]` 也可直接切换回 Realm。

### 切换流程

1. **预览** —— 列出全部待转换规则的转换前 / 转换后形态，并提示本次转换的有损项
2. **写入方式** —— 目标侧已有规则时可选「覆盖」或「合并（端口冲突跳过）」
3. **源侧处理** —— 迁移后如何处理原方式：
   - 停用服务并清空规则（彻底切换）
   - 停用服务但保留规则（默认，可随时切回）
   - 保持原方式运行（不推荐，会造成端口争抢）
4. **自动备份** —— 切换前的 `config.toml` 与 `rules.conf` 连同服务状态一并存档
5. **应用** —— 写入规则、重启对应服务并校验是否接管成功

### 安全保障

- 每次切换（以及每次回滚）都会自动备份，保留最近 10 份，路径 `/root/realm/switch-backups/`
- 回滚会同时还原两侧规则文件与切换前的服务启停状态
- `iptables ➜ Realm` 时若 Realm 未能成功启动，会自动保留 iptables 规则，避免转发中断

### 转换对照

| 项目 | Realm ➜ iptables | iptables ➜ Realm |
| --- | --- | --- |
| 监听端口 | `[::]:8080` → `--dport 8080` 双栈 | 双栈 → `[::]:8080` |
| | `0.0.0.0:8080` → 仅 IPv4 | 仅 IPv4 → `0.0.0.0:8080` |
| 目标地址 | 原样保留（IPv6 自动去方括号） | 原样保留（IPv6 自动补方括号） |
| 备注 | 原样保留 | 原样保留 |
| 协议 | 取自 Realm `[network]` 全局设置 | 全部规则协议一致时可同步写入全局设置 |

### 已知有损项（切换前会明确提示）

- Realm 绑定了具体 IP 的监听地址（如 `10.0.0.5:6060`），转换后监听全部地址
- iptables 的「仅 IPv6」规则在 Realm 中以 `[::]` 双栈监听，切回时会变成双栈
- iptables 各规则的单独协议设置，在 Realm 中只能表达为一个全局开关；协议混用时统一按 TCP+UDP 处理
- Realm 的域名目标切到 iptables 后不再自动跟随 DNS 变化，域名 IP 变动需重新应用规则

---

## 配置文件示例

配置文件路径：`/root/realm/config.toml`

```toml
[network]
no_tcp = false
use_udp = true

[[endpoints]]
# 备注: 示例规则
listen = "[::]:10000"
remote = "1.2.3.4:443"
```

---

## 中国网络优化

脚本启动时会自动检测 IP 位置：

* 若检测为 **中国 IP**，将提示配置 GitHub 反代加速
* 默认反代地址：`https://acc.banez.de/`
* 支持自定义反代地址
* 配置自动保存，下次启动无需重复配置

---

## 文件位置说明

| 文件类型     | 路径                                  |
| -------- | ----------------------------------- |
| Realm 程序 | `/root/realm/realm`                 |
| 配置文件     | `/root/realm/config.toml`           |
| 服务文件     | `/etc/systemd/system/realm.service` |
| 日志文件     | `/var/log/realm_manager.log`        |
| 代理配置     | `/root/realm/.proxy_config`         |
| iptables 规则 | `/root/iptables-forward/rules.conf` |
| iptables 应用脚本 | `/root/iptables-forward/apply.sh` |
| iptables 服务 | `/etc/systemd/system/iptables-forward.service` |
| 切换备份     | `/root/realm/switch-backups/`       |

---

## 常见问题

### 安装失败

* 检查网络连接
* 中国用户建议使用反代安装
* 确保使用 root 权限运行

---

### 服务启动失败

```bash
# 检查配置文件格式
cat /root/realm/config.toml

# 检查端口是否被占用
ss -tlnp | grep 端口号

# 查看服务日志
journalctl -u realm -n 50
```

---

### 规则添加后不生效

* 确保服务已重启
* 检查防火墙 / 安全组规则

---

## 命令行参数

```bash
./realm.sh --no-update    # 跳过自动更新检查
./realm.sh --no-proxy     # 跳过代理配置
```

---

## 致谢

* **Realm** —— 高性能端口转发工具
* **EZrealm** —— 原始脚本项目

---

## 许可证

**MIT License**

