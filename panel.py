"""Realm, iptables and nftables forwarding manager."""

import argparse
import base64
import copy
import csv
import fcntl
import hashlib
import io
import ipaddress
import json
import os
import platform
import re
import shlex
import shutil
import socket
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request
from pathlib import Path

import tomlkit as toml

ROOT = Path("/root/realm")
STATE = ROOT / "panel.toml"
CONFIG = ROOT / "config.toml"
BIN = ROOT / "realm"
LIB = Path("/usr/local/lib/realm-panel/panel.py")
UNITS = Path("/etc/systemd/system")
LEGACY = Path("/root/iptables-forward")
BOOT = "realm-panel-nat.service"
REALM = "realm.service"
OLD = "iptables-forward.service"
PLAN = ROOT / "nat.json"
JOURNAL = ROOT / "pending.json"
BACKENDS = ("realm", "iptables", "nftables")
GUIDE = """Realm     用户态代理，可跨 IPv4/IPv6、动态解析域名，支持负载均衡、TLS、PROXY 和 MPTCP。占用进程和监听端口，重启影响现有连接。
iptables  内核 DNAT，适合已有 xtables 的机器；无代理进程。按地址族提交，规则量大时逐条匹配，只转发同族入站流量。
nftables  内核 DNAT，在一次事务中提交双栈规则，适合新部署。需要 nft 和内核 NAT 支持。
两种 NAT 都需要 IP forwarding 和允许流量通过的 FORWARD 策略；域名使用系统 DNS，在应用时固定为 IP。面板对匹配连接做源 NAT。"""
EMPTY = "[network]\nno_tcp = false\nuse_udp = true\n"
REPO = "https://api.github.com/repos/zhboner/realm"


def run(args, data=None, check=True):
    p = subprocess.run(args, input=data, capture_output=True, text=True, check=False)
    if check and p.returncode:
        raise ValueError(f"{shlex.join(args)}: {p.stderr.strip() or p.stdout.strip() or p.returncode}")
    return p


def atomic(path, content, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(content, str):
        content = content.encode()
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as f:
        tmp = Path(f.name)
        try:
            os.fchmod(f.fileno(), mode)
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
            os.replace(tmp, path)
        finally:
            tmp.unlink(missing_ok=True)
    fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def read(path, default=None):
    return path.read_text() if path.exists() else default


def port(value):
    if not str(value).isascii() or not str(value).isdigit() or not 1 <= int(value) <= 65535:
        raise ValueError(f"无效端口 {value}")
    return int(value)


def hostport(host, number):
    return f"[{host}]:{number}" if ":" in host else f"{host}:{number}"


def address(value, local=False):
    host, sep, n = value.rpartition(":")
    if not sep:
        raise ValueError(f"缺少端口 {value}")
    if host.startswith("[") and host.endswith("]"):
        host = host[1:-1]
    if "%" in host:
        raise ValueError("不支持带作用域标识的地址")
    try:
        host = str(ipaddress.ip_address(host))
    except ValueError:
        if (
            local
            or not re.fullmatch(
                r"(?=.{1,253}\.?$)(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)*[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.?",
                host,
            )
            or re.fullmatch(r"[\d.]+", host)
        ):
            raise ValueError(f"无效地址 {value}")
    return host, port(n)


def endpoint(backend, listen, remote, proto, v6only=False, name=""):
    if backend not in BACKENDS or proto not in ("tcp", "udp", "both"):
        raise ValueError("后端或协议无效")
    lh, lp = address(listen, True)
    rh, rp = address(remote)
    e = toml.table()
    e["listen"], e["remote"] = hostport(lh, lp), hostport(rh, rp)
    e["panel_backend"], e["panel_name"] = backend, name
    net = toml.inline_table()
    net.update(no_tcp=proto == "udp", use_udp=proto != "tcp", ipv6_only=v6only)
    e["network"] = net
    return e


def add(doc, e):
    if "endpoints" not in doc or not len(doc["endpoints"]):
        doc["endpoints"] = toml.aot()
    doc["endpoints"].append(e)


def backend(e):
    return e.get("panel_backend", "realm")


def layout(doc, e):
    net = dict(doc.get("network", {}))
    net.update(e.get("network", {}))
    host, n = address(e["listen"], local=backend(e) != "realm")
    try:
        ipaddress.ip_address(host)
    except ValueError:
        host = socket.getaddrinfo(host, n, type=socket.SOCK_STREAM)[0][4][0]
    protocols = (["tcp"] if not net.get("no_tcp", False) else []) + (
        ["udp"] if net.get("use_udp", False) else []
    )
    if not protocols:
        raise ValueError(f"{e['listen']} 未开启 TCP 或 UDP")
    binds = [host]
    if host == "::" and not net.get("ipv6_only", False):
        binds.append("0.0.0.0")
    return net, binds, n, protocols


def validate(doc):
    seen = {}
    incompatible = []
    for i, e in enumerate(doc.get("endpoints", []), 1):
        if backend(e) not in BACKENDS:
            raise ValueError(f"规则 {i} 的后端无效")
        address(e["remote"])
        net, binds, n, protocols = layout(doc, e)
        if backend(e) != "realm":
            extra = set(e) - {"listen", "remote", "network", "panel_name", "panel_backend"}
            extra.update(
                k for k, v in net.items() if k not in ("no_tcp", "use_udp", "ipv6_only") and v is not False
            )
            if extra:
                incompatible.append(
                    f"规则 {i} ({e['listen']}) 无法在 NAT 保留这些 Realm 设置: {', '.join(sorted(extra))}"
                )
        for host in binds:
            ip = ipaddress.ip_address(host)
            for proto in protocols:
                others = seen.setdefault((ip.version, n, proto), {})
                for other, idx in others.items():
                    if ip == other or ip.is_unspecified or other.is_unspecified:
                        raise ValueError(f"规则 {idx} 与 {i} 的 {hostport(host, n)}/{proto} 冲突")
                others[ip] = i
    if incompatible:
        raise ValueError("\n".join(incompatible))


def realm_text(doc):
    runtime = copy.deepcopy(doc)
    endpoints = runtime.get("endpoints", [])
    for i in reversed(range(len(endpoints))):
        e = endpoints[i]
        if backend(e) != "realm":
            del endpoints[i]
        else:
            e.pop("panel_backend", None)
            e.pop("panel_name", None)
    if not endpoints:
        runtime.pop("endpoints", None)
        runtime["endpoints"] = []
    return toml.dumps(runtime)


def legacy_rules(doc):
    for i, line in enumerate(read(LEGACY / "rules.conf", "").splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        try:
            lp, proto, host, rp, name, mode = line.split("|")
            listen = {"1": "::", "2": "0.0.0.0", "3": "::"}[mode]
            add(
                doc,
                endpoint(
                    "iptables", hostport(listen, lp), hostport(host.strip("[]"), rp), proto, mode == "3", name
                ),
            )
        except (KeyError, ValueError) as exc:
            raise ValueError(f"旧 rules.conf 第 {i} 行: {exc}") from exc


def load():
    if STATE.exists():
        return toml.parse(STATE.read_text())
    doc = toml.parse(read(CONFIG, EMPTY))
    legacy_rules(doc)
    return doc


def nat_plan(doc):
    result = []
    for e in doc.get("endpoints", []):
        if backend(e) == "realm":
            continue
        _, binds, lp, protocols = layout(doc, e)
        host, rp = address(e["remote"])
        ips = [ipaddress.ip_address(x[4][0]) for x in socket.getaddrinfo(host, rp, type=socket.SOCK_STREAM)]
        count = 0
        for bind in binds:
            family = ipaddress.ip_address(bind).version
            target = next((ip for ip in ips if ip.version == family), None)
            if target is None:
                print(
                    f"提示 {e['listen']} → {host}: IPv{family} 无同族目标，此地址族无法由 NAT 转发。",
                    file=sys.stderr,
                )
                continue
            for proto in protocols:
                result.append([backend(e), family, bind, lp, proto, str(target), rp])
            count += 1
        if not count:
            raise ValueError(f"{e['listen']} → {host} 没有可用的同族目标")
    return result


# Dedicated conntrack bit used only on matching incoming connections.
BIT = "0x40000000"
CHAINS = {"PREROUTING": "RFP_PRE", "POSTROUTING": "RFP_POST"}
NFT = "realm_panel"


def xt_snapshot(family, chains=CHAINS):
    binary = "iptables" if family == 4 else "ip6tables"
    lines = run([binary, "-w", "5", "-t", "nat", "-S"]).stdout.splitlines()
    names = set(chains.values())
    create = [s for s in lines if s.startswith("-N ") and s.split()[1] in names]
    rules = [s for s in lines if s.startswith("-A ") and s.split()[1] in names]
    hooks = [f"-A {base} -j {chain}" for base, chain in chains.items() if f"-A {base} -j {chain}" in lines]
    return create, rules, hooks


def local_addresses(family):
    label = "inet" if family == 4 else "inet6"
    interfaces = json.loads(run(["ip", "-j", "address", "show"]).stdout)
    addresses = sorted(
        {
            str(ipaddress.ip_address(a["local"]))
            for iface in interfaces
            for a in iface["addr_info"]
            if a["family"] == label
        }
    )
    if not addresses:
        raise ValueError(f"IPv{family} 通配监听缺少本地地址")
    return addresses


def xt_target(rows):
    if not rows:
        return [], [], []
    rules = []
    addresses = {}
    for _, family, bind, lp, proto, remote, rp in rows:
        if ipaddress.ip_address(bind).is_unspecified:
            if family not in addresses:
                addresses[family] = local_addresses(family)
            local = addresses[family]
        else:
            local = [bind]
        for ip in local:
            rules.append(
                f"-A RFP_PRE -d {ip} -p {proto} --dport {lp} -j DNAT --to-destination {hostport(remote, rp)}"
            )
            rules.append(
                f"-A RFP_POST -d {remote} -p {proto} --dport {rp} -m conntrack --ctstate DNAT "
                f"--ctorigdst {ip} --ctorigdstport {lp} -j MASQUERADE"
            )
    return [f"-N {x}" for x in CHAINS.values()], rules, [f"-A {b} -j {c}" for b, c in CHAINS.items()]


def xt_set(family, target, test=False, chains=CHAINS):
    old, _, hooks = xt_snapshot(family, chains)
    create, rules, desired_hooks = target
    lines = ["*nat"]
    lines.extend(s.replace("-A ", "-D ", 1) for s in hooks if s not in desired_hooks)
    lines.extend(s.replace("-N", "-F", 1) for s in old)
    lines.extend(s.replace("-N", "-X", 1) for s in old if s not in create)
    lines.extend(s for s in create if s not in old)
    lines.extend(rules)
    lines.extend(s.replace("-A ", "-I ", 1) for s in desired_hooks if s not in hooks)
    binary = "iptables-restore" if family == 4 else "ip6tables-restore"
    run(
        [binary, "--wait", "5", "--noflush"] + (["--test"] if test else []), "\n".join(lines + ["COMMIT", ""])
    )


def nft_snapshot():
    tables = run(["nft", "list", "tables"]).stdout.splitlines()
    if f"table inet {NFT}" in tables:
        return run(["nft", "list", "table", "inet", NFT]).stdout
    return ""


def nft_target(rows):
    if not rows:
        return ""
    lines = [f"table inet {NFT} {{", " chain pre { type nat hook prerouting priority dstnat; policy accept;"]
    for _, family, bind, lp, proto, target, rp in rows:
        af = "ip" if family == 4 else "ip6"
        dest = "fib daddr type local" if ipaddress.ip_address(bind).is_unspecified else f"{af} daddr {bind}"
        lines.append(
            f"  meta nfproto ipv{family} {dest} {proto} dport {lp} ct mark set ct mark | {BIT} dnat {af} to {hostport(target, rp)}"
        )
    lines.extend(
        [
            " }",
            " chain post { type nat hook postrouting priority srcnat; policy accept;",
            f"  ct status dnat ct mark & {BIT} == {BIT} masquerade",
            " }",
            "}",
        ]
    )
    return "\n".join(lines) + "\n"


def nft_set(target, test=False):
    prefix = f"delete table inet {NFT}\n" if nft_snapshot() else ""
    if prefix or target:
        cmd = ["nft"] + (["-c"] if test else []) + ["-f", "-"]
        attempt = run(cmd, prefix + target, check=False)
        if not attempt.returncode:
            return
        if "fib daddr type local" not in target or "No such file or directory" not in attempt.stderr:
            raise ValueError(attempt.stderr)
        # Some kernels support inet NAT but omit nft_fib_inet. Still match local destinations only.
        for family, af in [(4, "ip"), (6, "ip6")]:
            marker = f"meta nfproto ipv{family} fib daddr type local"
            if marker not in target:
                continue
            local = local_addresses(family)
            target = target.replace(marker, af + " daddr { " + ", ".join(local) + " }")
        print("内核缺少通配 FIB 匹配，已按当前本机地址生成规则；网卡地址变化后请重新应用。", file=sys.stderr)
        run(cmd, prefix + target)


def xt_families(rows):
    return sorted({r[1] for r in rows if r[0] == "iptables"})


def firewall(old, new, test=False):
    for family in xt_families(old + new):
        xt_set(family, xt_target([r for r in new if r[:2] == ["iptables", family]]), test)
    if any(r[0] == "nftables" for r in old + new):
        nft_set(nft_target([r for r in new if r[0] == "nftables"]), test)


def forward_key(family):
    return "net.ipv4.ip_forward" if family == 4 else "net.ipv6.conf.all.forwarding"


def enable_forward(rows):
    for family in sorted({r[1] for r in rows}):
        key = forward_key(family)
        if run(["sysctl", "-n", key]).stdout.strip() != "1":
            run(["sysctl", "-w", key + "=1"])


def service(action, unit):
    run(["systemctl", action, unit])


def status(action, unit):
    return run(["systemctl", action, "--quiet", unit], check=False).returncode == 0


def verify_realm(doc):
    required = []
    for e in doc.get("endpoints", []):
        if backend(e) == "realm":
            _, binds, n, protocols = layout(doc, e)
            required.extend((binds[0], n, p) for p in protocols)
    for _ in range(25):
        pid = run(["systemctl", "show", "-p", "MainPID", "--value", REALM]).stdout.strip()
        sockets = run(["ss", "-Hlnptu"]).stdout.splitlines()
        found = set()
        for line in sockets:
            fields = line.split()
            if len(fields) >= 5 and f"pid={pid}," in line:
                local, _, number = fields[4].rpartition(":")
                local = re.sub(r"%[^\]]+", "", local)
                found.add((f"{local}:{number}", fields[0]))
        if pid != "0" and all(
            (hostport(h, n), p) in found or (h == "::" and (f"*:{n}", p) in found) for h, n, p in required
        ):
            return
        time.sleep(0.2)
    raise ValueError("Realm 未建立预期的监听套接字，请检查 journalctl -u realm")


REALM_UNIT = """[Unit]
Description=Realm TCP/UDP forwarding
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/root/realm
ExecStart=/root/realm/realm -c /root/realm/config.toml
Restart=on-failure
RestartSec=2
NoNewPrivileges=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes

[Install]
WantedBy=multi-user.target
"""
BOOT_UNIT = """[Unit]
Description=Restore forwarding panel NAT rules
Wants=network-online.target
After=network-online.target nftables.service netfilter-persistent.service
Before=realm.service

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /usr/local/lib/realm-panel/panel.py restore
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
"""
OLD_CHAIN = {"PREROUTING": "IPT-FORWARD"}


def old_unit():
    path = UNITS / OLD
    if path.exists():
        if (
            f"ExecStart={LEGACY}/apply.sh" not in path.read_text()
            or "# Auto-generated by Realm-TCP-UDP-Forwarding-Panel" not in read(LEGACY / "apply.sh", "")
        ):
            raise ValueError(f"无法确认 {path} 归属")
        return True
    return False


def capture_legacy():
    saved = {}
    if STATE.exists() or not (LEGACY / "rules.conf").exists():
        return saved
    identified = old_unit() or "# Auto-generated by Realm-TCP-UDP-Forwarding-Panel" in read(
        LEGACY / "apply.sh", ""
    )
    for family in (4, 6):
        binary = "iptables" if family == 4 else "ip6tables"
        if shutil.which(binary):
            probe = run([binary, "-w", "5", "-t", "nat", "-S"], check=False)
            if probe.returncode and family == 6 and "Table does not exist" in probe.stderr:
                continue
            if probe.returncode:
                raise ValueError(probe.stderr)
            old = xt_snapshot(family, OLD_CHAIN)
            if old[0]:
                if not identified:
                    raise ValueError("旧 IPT-FORWARD 链归属不明，请先核对")
                saved[str(family)] = old
    return saved


def snapshot(paths):
    return {str(p): read(p) for p in paths}


def restore_files(files):
    for name, content in files.items():
        path = Path(name)
        if content is None:
            path.unlink(missing_ok=True)
        else:
            atomic(path, content, 0o644 if path.parent == UNITS else 0o600)


def recover(j, boot=False):
    # Keep the journal until all restoration operations succeed.
    if j["files"][str(UNITS / BOOT)] is None and (UNITS / BOOT).exists():
        service("disable", BOOT)
    restore_files(j["files"])
    run(["systemctl", "daemon-reload"])
    for fam, old in j["xt"].items():
        xt_set(int(fam), old)
    if j["nft"] is not None:
        nft_set(j["nft"])
    if j.get("old_active") and not boot:
        service("start", OLD)
    for fam, old in j["legacy"].items():
        xt_set(int(fam), old, chains=OLD_CHAIN)
    for key, value in j["sysctl"].items():
        run(["sysctl", "-w", f"{key}={value}"])
    for unit, enabled in j["enabled"].items():
        if (UNITS / unit).exists() or enabled:
            service("enable" if enabled else "disable", unit)
    if j["realm_changed"] and (UNITS / REALM).exists() and not boot:
        service("restart" if j["active"] else "stop", REALM)
    JOURNAL.unlink()


def commit(before, doc, plan, importing=False):
    oldplan = json.loads(read(PLAN, "[]"))
    runtime = realm_text(doc)
    had_realm = any(backend(e) == "realm" for e in before.get("endpoints", []))
    has_realm = any(backend(e) == "realm" for e in doc.get("endpoints", []))
    different = read(CONFIG) != runtime
    change = (has_realm and (different or not status("is-active", REALM))) or (had_realm and not has_realm)
    if has_realm and (not BIN.is_file() or not (UNITS / REALM).exists()):
        raise ValueError("请先通过菜单 1 安装 Realm，再应用 Realm 规则")
    if STATE.exists() and read(CONFIG) != realm_text(before) and not importing:
        raise ValueError("config.toml 已从外部修改，请先导出备份并使用导入功能合并变更")
    legacy = capture_legacy()
    retire = not STATE.exists() and (LEGACY / "rules.conf").exists() and old_unit()
    xt = {str(f): xt_snapshot(f) for f in xt_families(oldplan + plan)}
    nft = nft_snapshot() if any(r[0] == "nftables" for r in oldplan + plan) else None
    # Never adopt an existing table/chain merely because it has our reserved name.
    for f, existing in xt.items():
        if existing[0] and int(f) not in xt_families(oldplan):
            raise ValueError("iptables 链名 RFP_PRE/RFP_POST 已被占用")
    if nft and not any(r[0] == "nftables" for r in oldplan):
        raise ValueError("nftables 表 inet realm_panel 已被占用")
    if (UNITS / BOOT).exists() and read(UNITS / BOOT) != BOOT_UNIT:
        raise ValueError(f"{BOOT} 已被其他配置占用")
    firewall(oldplan, plan, test=True)
    units = [BOOT] + ([REALM] if (UNITS / REALM).exists() else []) + ([OLD] if retire else [])
    j = {
        "xt": xt,
        "nft": nft,
        "legacy": legacy,
        "active": status("is-active", REALM),
        "realm_changed": bool(change),
        "enabled": {u: status("is-enabled", u) for u in units},
        "sysctl": {
            forward_key(f): run(["sysctl", "-n", forward_key(f)]).stdout.strip() for f in {r[1] for r in plan}
        },
        "old_active": retire and status("is-active", OLD),
        "files": snapshot([STATE, CONFIG, PLAN, UNITS / BOOT] + ([UNITS / OLD] if retire else [])),
    }
    atomic(ROOT / "previous.toml", toml.dumps(before))
    atomic(JOURNAL, json.dumps(j))
    try:
        atomic(LIB, Path(__file__).read_bytes(), 0o644)
        atomic(UNITS / BOOT, BOOT_UNIT, 0o644)
        run(["systemctl", "daemon-reload"])
        service("enable", BOOT)
        if retire:
            run(["systemctl", "disable", "--now", OLD])
            atomic(ROOT / "legacy-iptables.service.bak", (UNITS / OLD).read_text())
            (UNITS / OLD).unlink()
            run(["systemctl", "daemon-reload"])
        enable_forward(plan)
        if runtime != read(CONFIG):
            atomic(CONFIG, runtime)
        if change and has_realm:
            service("restart", REALM)
            verify_realm(doc)
            service("enable", REALM)
        firewall(oldplan, plan)
        for fam in legacy:
            xt_set(int(fam), ([], [], []), chains=OLD_CHAIN)
        if change and not has_realm and (UNITS / REALM).exists():
            service("stop", REALM)
            service("disable", REALM)
        atomic(PLAN, json.dumps(plan))
        atomic(STATE, toml.dumps(doc))
        JOURNAL.unlink()
    except (Exception, KeyboardInterrupt):
        recover(j)
        raise
    if retire or legacy:
        print("0.4.0 已接管。旧版无条件 MASQUERADE 无归属标记，请核对是否有其他服务使用后手工处理。")


def restore_boot():
    if JOURNAL.exists():
        recover(json.loads(JOURNAL.read_text()), boot=True)
    rows = json.loads(read(PLAN, "[]"))
    enable_forward(rows)
    firewall(rows, rows)


def yes(prompt):
    return input(prompt + " [y/N] ").strip().lower() == "y"


def list_rules(doc):
    for i, e in enumerate(doc.get("endpoints", []), 1):
        _, _, _, protos = layout(doc, e)
        name = e.get("panel_name", "")
        if not name and isinstance(e, toml.items.Table):
            for key, item in e.value.body:
                if key is None and isinstance(item, toml.items.Comment):
                    comment = item.as_string().strip()
                    if comment.startswith("# 备注:"):
                        name = comment.partition(":")[2].strip()
                        break
        print(f"{i:3}  {backend(e):9} {'+'.join(protos):7} {e['listen']} → {e['remote']}  {name}")
    if not doc.get("endpoints"):
        print("尚无转发规则")


def choose_backend():
    choice = input("后端  1 Realm  2 iptables  3 nftables  [1] ").strip() or "1"
    return BACKENDS[int(choice) - 1] if choice in ("1", "2", "3") else pick_backend(choice)


def pick_backend(value):
    if value not in BACKENDS:
        raise ValueError("未知后端")
    return value


def select(spec, doc):
    total = len(doc.get("endpoints", []))
    if spec.lower() in BACKENDS:
        return [i for i, e in enumerate(doc.get("endpoints", [])) if backend(e) == spec.lower()]
    if spec.lower() in ("all", "*"):
        return list(range(total))
    result = set()
    for item in spec.split(","):
        lo, _, hi = item.partition("-")
        lo, hi = int(lo), int(hi or lo)
        if not 1 <= lo <= hi <= total:
            raise ValueError(f"规则序号越界 {item}")
        result.update(range(lo - 1, hi))
    return sorted(result)


def create(doc):
    print(GUIDE)
    b = choose_backend()
    mode = input("1 单条  2 批量 CSV  [1] ").strip() or "1"
    if mode == "2":
        print("本地端口,目标地址,目标端口[,备注,监听模式,协议]；模式 1 双栈 / 2 IPv4 / 3 IPv6；空行结束")
        while True:
            line = input("> ")
            if not line:
                break
            row = next(csv.reader([line]))
            if not 3 <= len(row) <= 6:
                raise ValueError("CSV 需要 3 至 6 列")
            lp, rh, rp, name, family, proto = (row + [""] * 3)[:6]
            family = family or "1"
            lh = {"1": "::", "2": "0.0.0.0", "3": "::"}[family]
            add(
                doc,
                endpoint(
                    b,
                    hostport(lh, port(lp)),
                    hostport(rh.strip("[]"), port(rp)),
                    proto or "both",
                    family == "3",
                    name,
                ),
            )
    elif mode == "1":
        listen = input("监听 IP:端口（例 0.0.0.0:8080 或 [::]:8080） ").strip()
        rh = input("目标 IP 或域名 ").strip().strip("[]")
        rp = port(input("目标端口 ").strip())
        proto = input("协议 tcp / udp / both [both] ").strip() or "both"
        v6 = address(listen, True)[0] == "::" and yes("仅 IPv6 监听？")
        e = endpoint(b, listen, hostport(rh, rp), proto, v6, input("备注 "))
        if b == "realm" and yes("配置 Realm 高级选项（多后端、MPTCP、TLS、PROXY 等）？"):
            print(
                '输入 endpoint TOML，空行结束。例如 extra_remotes = ["192.0.2.2:443"] 或 network.send_mptcp = true'
            )
            extra = multiline()
            for k, v in extra.items():
                if k == "network":
                    e[k].update(v)
                elif k in {
                    "balance",
                    "extra_remotes",
                    "through",
                    "interface",
                    "listen_interface",
                    "listen_transport",
                    "remote_transport",
                }:
                    e[k] = v
                else:
                    raise ValueError(f"未知 endpoint 高级选项 {k}")
        add(doc, e)
    else:
        raise ValueError("无效创建模式")


def multiline():
    lines = []
    while True:
        line = input("> ")
        if not line:
            return toml.parse("\n".join(lines))
        lines.append(line)


def dns_edit(doc):
    print("当前 DNS:", doc.get("dns", {}))
    choice = input("1 Google + Cloudflare  2 Cloudflare  3 自定义 TOML  4 调整 TTL  5 系统 DNS  0 返回 ")
    ns = ["1.1.1.1:53", "1.0.0.1:53", "[2606:4700:4700::1111]:53", "[2606:4700:4700::1001]:53"]
    if choice in ("1", "2"):
        if choice == "1":
            ns += ["8.8.8.8:53", "8.8.4.4:53", "[2001:4860:4860::8888]:53"]
        doc["dns"] = {
            "mode": "ipv4_and_ipv6",
            "protocol": "tcp_and_udp",
            "nameservers": ns,
            "min_ttl": 0,
            "max_ttl": 300,
            "cache_size": 256,
        }
    elif choice == "3":
        print('输入 DNS 字段，例如 mode = "ipv4_only"，空行结束')
        doc["dns"] = multiline().unwrap()
    elif choice == "4":
        ttl = int(input("最大 TTL 秒数 "))
        if not int(doc.get("dns", {}).get("min_ttl", 0)) <= ttl <= 4294967295:
            raise ValueError("TTL 超出范围")
        if "dns" not in doc:
            doc["dns"] = toml.table()
        doc["dns"]["max_ttl"] = ttl
    elif choice == "5":
        doc.pop("dns", None)
    elif choice != "0":
        raise ValueError("无效 DNS 模式")


def display_plan(plan):
    for b, _, bind, lp, proto, target, rp in plan:
        print(f"  {b} {proto} {hostport(bind, lp)} → {hostport(target, rp)}")


def change_rules(action, args, assume_yes=False, dry_run=False):
    old = load()
    doc = copy.deepcopy(old)
    if action == "list":
        list_rules(doc)
        return
    if action == "create":
        create(doc)
    elif action == "dns":
        dns_edit(doc)
    elif action in ("delete", "migrate"):
        if not args:
            list_rules(doc)
        indices = select(args[0] if args else input("规则序号、范围、来源后端或 all "), doc)
        if action == "delete":
            for i in reversed(indices):
                del doc["endpoints"][i]
        else:
            print(GUIDE)
            b = pick_backend(args[1]) if len(args) > 1 else choose_backend()
            for i in indices:
                doc["endpoints"][i]["panel_backend"] = b
            print(
                "切换可能中断已有连接。NAT 使用同族地址和系统 DNS；已建立的 NAT 连接受 conntrack 超时影响。"
            )
    elif action in ("import", "export"):
        target = args[0] if args else input("文件路径，或输入 base64（完整面板 TOML，兼容旧 Realm TOML） ")
        if action == "export":
            if target == "base64":
                print(base64.b64encode(toml.dumps(doc).encode()).decode())
            else:
                path = Path(target)
                if path.exists() and not yes("覆盖已有文件？"):
                    return
                atomic(path, toml.dumps(doc))
            return
        content = (
            base64.b64decode(input("Base64 "), validate=True).decode()
            if target == "base64"
            else Path(target).read_text()
        )
        doc = toml.parse(content)
        if not set(doc).intersection({"endpoints", "network", "log", "dns"}):
            raise ValueError("文件缺少 Realm 配置字段")
    if toml.dumps(old) == toml.dumps(doc) and action not in ("apply", "import"):
        print("配置没有变化")
        return
    validate(doc)
    plan = nat_plan(doc)
    print("应用后的规则")
    list_rules(doc)
    display_plan(plan)
    if dry_run:
        return
    if assume_yes or yes("确认整体应用？"):
        if any(backend(e) == "realm" for e in doc.get("endpoints", [])) and (
            not BIN.is_file() or not (UNITS / REALM).exists()
        ):
            print("目标规则需要 Realm，正在安装上游完整版")
            install_realm()
        commit(old, doc, plan, importing=(action == "import"))
        print("已应用")


def fetch(url, proxy=""):
    req = urllib.request.Request(proxy + url, headers={"User-Agent": "Realm-Forwarding-Panel"})
    with urllib.request.urlopen(req, timeout=40) as res:
        return res.read()


def install_realm(tag=None):
    arch = {"amd64": "x86_64", "arm64": "aarch64", "armv7l": "armv7"}.get(
        platform.machine(), platform.machine()
    )
    if tag and not re.fullmatch(r"v\d+\.\d+\.\d+(?:-\d+)?", tag):
        raise ValueError("版本格式示例 v2.9.6")
    release = json.loads(fetch(REPO + "/releases/" + ("tags/" + tag if tag else "latest")))
    version = release["tag_name"]
    if not re.fullmatch(r"v\d+\.\d+\.\d+(?:-\d+)?", version):
        raise ValueError("上游版本号无效")
    suffix = "musleabihf" if arch == "armv7" else "musl"
    names = [
        f"realm-{arch}-unknown-linux-{suffix}.tar.gz",
        f"realm-{arch}-unknown-linux-gnu-glibc2.28.tar.gz",
        f"realm-{arch}-unknown-linux-gnu.tar.gz",
    ]
    assets = {a["name"]: a for a in release["assets"]}
    asset = next((assets[n] for n in names if n in assets), None)
    if not asset or not re.fullmatch(r"sha256:[a-f0-9]{64}", asset.get("digest") or ""):
        raise ValueError("上游缺少适用的完整版 Linux 资产或可信摘要")
    if BIN.exists():
        current = run([str(BIN), "--version"]).stdout.strip()
        print("已安装", current)
        match = re.search(r"\b(\d+\.\d+\.\d+)\b", current)
        if (
            match
            and tuple(map(int, match[1].split("."))) > tuple(map(int, version[1:].split("-")[0].split(".")))
            and not tag
        ):
            raise ValueError("保留已安装的较高版本；显式指定标签才能降级")
    print(f"安装 {version} / {asset['name']}")
    archive = fetch(asset["browser_download_url"], os.getenv("REALM_DOWNLOAD_PROXY", ""))
    if "sha256:" + hashlib.sha256(archive).hexdigest() != asset["digest"]:
        raise ValueError("上游 SHA-256 校验失败")
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as tar:
        member = next((m for m in tar if m.name in ("realm", "./realm") and m.isfile()), None)
        if not member:
            raise ValueError("压缩包缺少 Realm")
        binary = tar.extractfile(member).read()
    doc = load()
    running = status("is-active", REALM)
    unit = UNITS / REALM
    old = snapshot([unit, CONFIG])
    with tempfile.TemporaryDirectory(dir=ROOT) as tmp:
        stage = Path(tmp) / "realm"
        atomic(stage, binary, 0o755)
        result = run([str(stage), "--version"]).stdout
        if not re.search(r"\b" + re.escape(version[1:].split("-")[0]) + r"\b", result):
            raise ValueError("下载版本与标签不符")
        previous = Path(tmp) / "previous"
        if BIN.exists():
            os.link(BIN, previous)
        try:
            os.replace(stage, BIN)
            if not unit.exists():
                atomic(unit, REALM_UNIT, 0o644)
            if not CONFIG.exists():
                atomic(CONFIG, realm_text(doc))
            run(["systemctl", "daemon-reload"])
            if running:
                service("restart", REALM)
                verify_realm(doc)
        except (Exception, KeyboardInterrupt):
            if previous.exists():
                os.replace(previous, BIN)
            else:
                BIN.unlink(missing_ok=True)
            restore_files(old)
            run(["systemctl", "daemon-reload"])
            if running:
                service("restart", REALM)
            raise
    print(result.strip())


def cleanup_cron():
    cron = Path("/etc/crontab")
    old = read(cron, "")
    clean = "".join(
        line
        for line in old.splitlines(True)
        if not re.fullmatch(r"0 \d{1,2} \* \* \* root /usr/bin/systemctl restart realm\n?", line)
    )
    if old != clean:
        atomic(cron, clean, cron.stat().st_mode & 0o777)


def uninstall():
    if not yes("删除全部面板规则、开机服务与程序？"):
        return
    old = load()
    doc = copy.deepcopy(old)
    doc.pop("endpoints", None)
    commit(old, doc, [])
    for unit in (REALM, BOOT):
        if (UNITS / unit).exists():
            run(["systemctl", "disable", "--now", unit])
            (UNITS / unit).unlink()
    if old_unit():
        run(["systemctl", "disable", "--now", OLD])
        (UNITS / OLD).unlink()
    for path in [
        LIB,
        STATE,
        CONFIG,
        BIN,
        PLAN,
        LEGACY / "apply.sh",
        LEGACY / "rules.conf",
        ROOT / ".proxy_config",
    ]:
        path.unlink(missing_ok=True)
    cleanup_cron()
    run(["systemctl", "daemon-reload"])
    print("面板已卸载。配置备份保存在 /root/realm/previous.toml。")


def main():
    parser = argparse.ArgumentParser(description="三后端转发管理；migrate 规则序号或 all 目标后端")
    parser.add_argument(
        "action",
        choices=[
            "create",
            "list",
            "delete",
            "migrate",
            "apply",
            "import",
            "export",
            "dns",
            "install",
            "uninstall",
            "restore",
            "cron-clean",
        ],
    )
    parser.add_argument("values", nargs="*")
    parser.add_argument("--yes", action="store_true", help="确认规则操作")
    parser.add_argument("--dry-run", action="store_true", help="仅预览规则变更")
    ns = parser.parse_args()
    if (ns.yes or ns.dry_run) and ns.action not in ("migrate", "apply", "import", "delete", "create", "dns"):
        parser.error("--yes/--dry-run 仅适用于规则变更")
    if ns.action == "migrate" and len(ns.values) > 2:
        parser.error("migrate [规则或来源后端] [目标后端]")
    if os.geteuid() != 0:
        parser.error("需要 root 权限")
    ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (ROOT / ".panel.lock").open("a") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        if ns.action == "restore":
            restore_boot()
            return
        if JOURNAL.exists():
            print("恢复上次中断的事务")
            recover(json.loads(JOURNAL.read_text()))
        if ns.action == "install":
            install_realm(next(iter(ns.values), None))
        elif ns.action == "uninstall":
            uninstall()
        elif ns.action == "cron-clean":
            cleanup_cron()
        else:
            change_rules(ns.action, ns.values, ns.yes, ns.dry_run)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, EOFError, KeyboardInterrupt) as exc:
        sys.exit(f"操作未完成: {exc}")
