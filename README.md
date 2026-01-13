````markdown
# Realm TCP/UDP Forwarding Panel

一个功能强大的 **Realm 端口转发管理脚本**，支持一键部署、规则管理、中国网络优化等功能。

---

## 功能特性

- **一键安装**  
  自动检测系统架构，下载最新版 Realm

- **规则管理**  
  添加、查看、删除端口转发规则

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
1. 安装/更新 Realm
2. 添加转发规则
3. 查看转发规则
4. 删除转发规则
5. 启动服务
6. 停止服务
7. 重启服务
8. 定时任务管理
9. 查看日志
10. 完全卸载
11. 代理设置
0. 退出脚本
```

---

## 转发规则

脚本支持三种监听模式：

| 模式     | 地址格式         | 说明                   |
| ------ | ------------ | -------------------- |
| 双栈监听   | `[::]:端口`    | 同时监听 IPv4 和 IPv6（默认） |
| 仅 IPv4 | `0.0.0.0:端口` | 仅监听 IPv4             |
| 自定义    | 用户输入         | 自定义监听地址              |

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

```
```
