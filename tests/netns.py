"""End-to-end traffic in disposable network namespaces; pass the Realm binary path."""

import copy
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import panel as p

V6 = os.getenv("RFP_TEST_AF") == "6"
HOST, CLIENT_IP, GATEWAY, TARGET = (
    ["2001:db8:1::1", "2001:db8:1::2", "2001:db8:2::1", "2001:db8:2::2"]
    if V6
    else ["192.0.2.1", "192.0.2.2", "192.0.2.5", "192.0.2.6"]
)
AF = "AF_INET6" if V6 else "AF_INET"

SERVER = f"""
import socket, threading
def serve(kind):
    s = socket.socket(socket.{AF}, kind)
    s.bind(('{TARGET}', 20001))
    if kind == socket.SOCK_STREAM:
        s.listen()
        while True:
            c,_ = s.accept()
            with c: c.sendall(c.recv(80))
    while True:
        data, addr = s.recvfrom(80)
        s.sendto(data, addr)
threading.Thread(target=serve,args=(socket.SOCK_STREAM,),daemon=True).start()
serve(socket.SOCK_DGRAM)
"""
CLIENT = f"""
import socket
for kind in (socket.SOCK_STREAM, socket.SOCK_DGRAM):
    with socket.socket(socket.{AF}, kind) as s:
        s.settimeout(3)
        s.connect(('{HOST}', 19001))
        s.sendall(b'forward-test')
        assert s.recv(80) == b'forward-test'
"""


def cmd(*args):
    subprocess.run(args, check=True)


class SystemdAdapter:
    """Exercise actual daemons and kernel rules with a process runner in unprivileged CI."""

    def __init__(self):
        self.run = p.run
        self.proc = None
        self.enabled = set()

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            self.proc.wait(timeout=5)
        self.proc = None

    def __call__(self, args, data=None, check=True):
        if args[0] != "systemctl":
            return self.run(args, data, check)
        op, unit = args[1], args[-1]
        code, out = 0, ""
        if op == "restart":
            self.stop()
            self.proc = subprocess.Popen([p.BIN, "-c", p.CONFIG], stdout=subprocess.DEVNULL)
        elif op == "stop":
            self.stop()
        elif op == "is-enabled":
            code = int(unit not in self.enabled)
        elif op == "enable":
            self.enabled.add(unit)
        elif op == "disable":
            self.enabled.discard(unit)
        elif op == "is-active":
            code = int(not self.proc or self.proc.poll() is not None)
        elif op == "show":
            out = str(self.proc.pid if self.proc else 0)
        elif op != "daemon-reload":
            raise AssertionError(args)
        return subprocess.CompletedProcess(args, code, out, "")


def node(name, router, peer):
    ns = subprocess.Popen(["unshare", "-n", "sleep", "300"])
    try:
        for _ in range(100):
            if Path(f"/proc/{ns.pid}/ns/net").stat().st_ino != Path("/proc/self/ns/net").stat().st_ino:
                break
            time.sleep(0.01)
        cmd("ip", "link", "add", name, "type", "veth", "peer", "name", name + "p")
        cmd("ip", "link", "set", name + "p", "netns", str(ns.pid))
        cmd("ip", "addr", "add", router + ("/64" if V6 else "/30"), "dev", name, *(["nodad"] if V6 else []))
        cmd("ip", "link", "set", name, "up")
        enter = ["nsenter", "-t", str(ns.pid), "-n"]
        cmd(*enter, "ip", "link", "set", "lo", "up")
        cmd(*enter, "ip", "link", "set", name + "p", "up")
        cmd(
            *enter,
            "ip",
            "addr",
            "add",
            peer + ("/64" if V6 else "/30"),
            "dev",
            name + "p",
            *(["nodad"] if V6 else []),
        )
        cmd(*enter, "ip", *(["-6"] if V6 else []), "route", "add", "default", "via", router)
        return ns, enter
    except BaseException:
        ns.terminate()
        ns.wait()
        raise


def exercise(tmp, binary, client):
    supervisor = SystemdAdapter()
    units = tmp / "units"
    units.mkdir()
    (units / p.REALM).write_text(p.REALM_UNIT)
    bindings = {
        "ROOT": tmp,
        "UNITS": units,
        "BIN": binary,
        "CONFIG": tmp / "config.toml",
        "STATE": tmp / "panel.toml",
        "PLAN": tmp / "nat.json",
        "JOURNAL": tmp / "pending.json",
        "LIB": tmp / "installed.py",
        "LEGACY": tmp / "old",
        "run": supervisor,
    }
    with patch.multiple(p, **bindings):
        doc = p.load()
        try:
            # Use the existing v0.4 Realm config on the normal CLI path.
            p.add(
                doc,
                p.endpoint(
                    "realm",
                    p.hostport("::" if V6 else "0.0.0.0", 19001),
                    p.hostport(TARGET, 20001),
                    "both",
                    V6,
                    name="echo",
                ),
            )
            p.CONFIG.write_text(p.realm_text(doc))
            p.BIN.chmod(0o755)
            family = 6 if V6 else 4
            p.LEGACY.mkdir()
            (p.LEGACY / "apply.sh").write_text("# Auto-generated by Realm-TCP-UDP-Forwarding-Panel")
            (p.LEGACY / "rules.conf").write_text(f"19002|tcp|{TARGET}|20001|old|{3 if V6 else 2}\n")
            (p.UNITS / p.OLD).write_text(f"[Service]\nExecStart={p.LEGACY}/apply.sh\n")
            supervisor.enabled.add(p.OLD)
            p.xt_set(family, (["-N IPT-FORWARD"], [], ["-A PREROUTING -j IPT-FORWARD"]), chains=p.OLD_CHAIN)
            with patch("builtins.input", return_value="y"):
                p.change_rules("apply", [])
                assert p.backend(p.load()["endpoints"][1]) == "iptables"
                assert p.xt_snapshot(family, p.OLD_CHAIN) == ([], [], [])
                assert p.OLD not in supervisor.enabled
                assert not (p.UNITS / p.OLD).exists()
                cmd(*client, sys.executable, "-c", CLIENT)
                for dest in ("iptables", "nftables", "realm", "nftables", "iptables", "realm"):
                    source = p.backend(p.load()["endpoints"][0])
                    p.change_rules("migrate", ["1", dest])
                    assert p.backend(p.load()["endpoints"][0]) == dest
                    if dest != "realm":
                        rows = p.json.loads(p.PLAN.read_text())
                        p.firewall(rows, [])
                        p.restore_boot()
                    cmd(*client, sys.executable, "-c", CLIENT)
                    print(f"PASS {source} -> {dest} TCP/UDP", flush=True)
            before = p.load()
            failed = copy.deepcopy(before)
            failed["endpoints"][0]["panel_backend"] = "nftables"
            # Inject a late failure after the firewall is installed and Realm has stopped.
            writer = p.atomic

            def fail_state(path, data, mode=0o600):
                if path == p.STATE and data != p.toml.dumps(before):
                    raise OSError("injected commit failure")
                writer(path, data, mode)

            with patch.object(p, "atomic", side_effect=fail_state):
                try:
                    p.commit(before, failed, p.nat_plan(failed))
                except OSError as exc:
                    assert "injected" in str(exc)
                else:
                    raise AssertionError("fault was not reached")
            assert p.load() == before and not p.JOURNAL.exists()
            time.sleep(0.2)
            cmd(*client, sys.executable, "-c", CLIENT)
            print("PASS rollback TCP/UDP", flush=True)
        finally:
            supervisor.stop()


if __name__ == "__main__":
    binary = Path(sys.argv[1]).resolve()
    current_ns = str(Path("/proc/self/ns/net").stat().st_ino)
    if "RFP_TEST_PARENT_NETNS" not in os.environ:
        os.environ["RFP_TEST_PARENT_NETNS"] = current_ns
        os.execvp("unshare", ["unshare", "-n" if os.geteuid() == 0 else "-Urn", sys.executable, *sys.argv])
    if current_ns == os.environ["RFP_TEST_PARENT_NETNS"]:
        sys.exit("Network namespace isolation failed")
    with tempfile.TemporaryDirectory() as directory:
        tmp = Path(directory)
        os.environ["XTABLES_LOCKFILE"] = str(tmp / "xtables.lock")
        cmd("ip", "link", "set", "lo", "up")
        left, client = node("client0", HOST, CLIENT_IP)
        right, remote = node("remote0", GATEWAY, TARGET)
        server = subprocess.Popen([*remote, sys.executable, "-c", SERVER])
        try:
            shutil.copy2(binary, tmp / "realm")
            exercise(tmp, tmp / "realm", client)
        finally:
            for child in (server, left, right):
                child.terminate()
                child.wait(timeout=5)
