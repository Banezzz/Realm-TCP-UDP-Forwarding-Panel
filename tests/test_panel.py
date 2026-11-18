import copy
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import panel as p


class Rules(unittest.TestCase):
    def test_toml_roundtrip(self):
        doc = p.toml.parse("""
[network]
use_udp = true
tcp_timeout = 20
[[endpoints]]
# 备注: front
listen = "0.0.0.0:80"
remote = "192.0.2.10:443"
extra_remotes = ["192.0.2.11:443"]
balance = "roundrobin: 1, 1"
[dns]
max_ttl = 30
""")
        with patch("builtins.input", return_value="2"):
            p.dns_edit(doc)
        self.assertEqual(doc["network"]["tcp_timeout"], 20)
        self.assertIn("# 备注: front", p.realm_text(doc))
        doc["endpoints"][0]["panel_backend"] = "iptables"
        with self.assertRaisesRegex(ValueError, "balance"):
            p.validate(doc)
        del doc["endpoints"][0]
        self.assertIn("dns", p.toml.parse(p.realm_text(doc)))

    def test_legacy_iptables(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(p, "LEGACY", Path(tmp)):
            (p.LEGACY / "rules.conf").write_text("123|udp|2001:db8::1|234|备注|3\n")
            doc = p.toml.document()
            p.legacy_rules(doc)
            rule = doc["endpoints"][0]
            self.assertEqual(p.nat_plan(doc), [["iptables", 6, "::", 123, "udp", "2001:db8::1", 234]])
            rule["panel_backend"] = "realm"
            self.assertEqual(rule["panel_name"], "备注")
            self.assertTrue(p.toml.parse(p.realm_text(doc))["endpoints"][0]["network"]["ipv6_only"])

    def test_mixed_backends_remain_editable_after_reload(self):
        doc = p.toml.parse(p.EMPTY)
        for i, b in enumerate(p.BACKENDS):
            p.add(doc, p.endpoint(b, f"0.0.0.0:{9000 + i}", "192.0.2.1:80", "both"))
        runtime = p.realm_text(doc)
        self.assertEqual(runtime, p.realm_text(p.toml.parse(p.toml.dumps(doc))))
        self.assertEqual(len(p.toml.parse(runtime)["endpoints"]), 1)

    def test_protocol_conflicts(self):
        doc = p.toml.parse(p.EMPTY)
        for b, proto in [("realm", "tcp"), ("nftables", "udp")]:
            p.add(doc, p.endpoint(b, "0.0.0.0:9000", "192.0.2.1:80", proto))
        p.validate(doc)
        p.add(doc, p.endpoint("iptables", "[::]:9000", "192.0.2.1:81", "tcp"))
        with self.assertRaisesRegex(ValueError, "冲突"):
            p.validate(doc)

    def test_six_migrations_preserve_fields(self):
        for source in p.BACKENDS:
            for dest in set(p.BACKENDS) - {source}:
                doc = p.toml.parse(p.EMPTY)
                p.add(doc, p.endpoint(source, "[::]:9001", "[2001:db8::1]:80", "udp", True, "hello"))
                p.validate(doc)
                before = copy.deepcopy(doc)
                doc["endpoints"][0]["panel_backend"] = dest
                p.validate(doc)
                runtime = p.toml.parse(p.realm_text(doc))
                self.assertEqual(len(runtime["endpoints"]), int(dest == "realm"))
                self.assertEqual(len(p.nat_plan(doc)), int(dest != "realm"))
                doc["endpoints"][0]["panel_backend"] = source
                self.assertEqual(doc, before)

    def test_ipv6_only_dns(self):
        doc = p.toml.parse(p.EMPTY)
        p.add(doc, p.endpoint("nftables", "[::]:201", "srv.example:202", "both", True))
        answer = [(p.socket.AF_INET6, p.socket.SOCK_STREAM, 6, "", ("2001:db8::2", 202, 0, 0))]
        with patch.object(p.socket, "getaddrinfo", return_value=answer):
            self.assertEqual([r[1] for r in p.nat_plan(doc)], [6, 6])

    def test_install_assets(self):
        import hashlib

        shell = Path(p.__file__).with_name("realm.sh").read_text()
        self.assertIn(hashlib.sha256(Path(p.__file__).read_bytes()).hexdigest(), shell)
        self.assertIn('CURRENT_VERSION="' + Path("version.txt").read_text().strip() + '"', shell)


if __name__ == "__main__":
    unittest.main()
