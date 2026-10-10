#!/usr/bin/env python3
"""
Unit and integration tests for GeoVPN v1 -> v2 configuration migration,
rollback, and downgrade preparation (AT-22, AT-23, FR-45, NFR-15).
"""
import unittest
import os
import subprocess
import tempfile
import shutil
import stat

class TestMigrate(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.repo_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        cls.ucode_bin = os.path.join(cls.repo_root, 'tools', 'bin', 'ucode')
        cls.lib_path = os.path.join(cls.repo_root, 'openwrt', 'geovpn-core', 'files', 'usr', 'share', 'ucode')
        cls.script_path = os.path.join(cls.repo_root, 'openwrt', 'geovpn-core', 'files', 'etc', 'uci-defaults', '91-geovpn-migrate')
        cls.has_ucode = os.path.exists(cls.ucode_bin) and subprocess.run([cls.ucode_bin, '-e', '1'], capture_output=True).returncode == 0

    def setUp(self):
        self.test_dir = tempfile.mkdtemp(prefix='geovpn_test_migrate_')
        self.conf_dir = os.path.join(self.test_dir, 'config')
        self.backup_dir = os.path.join(self.test_dir, 'backup')
        os.makedirs(self.conf_dir, exist_ok=True)
        os.makedirs(self.backup_dir, exist_ok=True)
        self.config_file = os.path.join(self.conf_dir, 'geovpn')

        # Sample baseline v1 config
        self.v1_sample = """config main 'main'
	option config_version '1'
	option enabled '1'
	option active_profile 'p11111111'
	option split_enabled '1'
	option mode 'bypass'
	option private_direct '1'
	option ipv6 'auto'
	option kill_switch '0'
	option router_traffic 'dns'
	list lan_ifs 'br-lan'
	option tun_dev 'geovpn0'
	option mark_shift '24'
	option rt_table '4200'
	option rule_priority '700'
	option dns_mode 'follow'
	list dns_direct_servers 'auto'
	list dns_vpn_servers '1.1.1.1'
	option dns_hijack '1'
	option block_dot '1'
	option block_doh '0'
	option dns_canary '1'

config data 'data'
	option source_url 'https://geovpn.github.io/geovpn-data/v1/'
	option verify '1'

config profile 'p11111111'
	option name 'Frankfurt Server'
	option enabled '1'
	list remote 'de.example.com 1194 udp'
	option cipher 'AES-256-GCM'

config profile 'p22222222'
	option name 'Amsterdam Server'
	option enabled '1'
	list remote 'nl.example.com 1194 udp'
	option cipher 'AES-128-GCM'
"""
        with open(self.config_file, 'w', encoding='utf-8') as f:
            f.write(self.v1_sample)

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def test_v1_to_v2_migration_ucode(self):
        """Test migrate_v1_to_v2 in ucode: adds proto 'openvpn', backup, test & autoconnect sections."""
        if not self.has_ucode:
            self.skipTest("ucode runtime not available")

        script = f"""
        import * as cfg from 'geovpn.config';
        let res = cfg.migrate_v1_to_v2('{self.conf_dir}', '{self.backup_dir}');
        print(sprintf('%J', res));
        """
        proc = subprocess.run([self.ucode_bin, '-L', self.lib_path, '-e', script], capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('"ok":true', proc.stdout.replace(' ', ''))

        # Check backup created
        backups = [f for f in os.listdir(self.backup_dir) if f.startswith('geovpn.v1.')]
        self.assertEqual(len(backups), 1, "Expected exactly 1 backup created")
        backup_file = os.path.join(self.backup_dir, backups[0])
        with open(backup_file, 'r', encoding='utf-8') as f:
            backup_content = f.read()
        self.assertEqual(backup_content, self.v1_sample, "Backup must match exact v1 content")

        # Check migrated config
        with open(self.config_file, 'r', encoding='utf-8') as f:
            migrated_content = f.read()

        self.assertIn("option config_version '2'", migrated_content)
        self.assertIn("option proto 'openvpn'", migrated_content)
        self.assertIn("config test 'test'", migrated_content)
        self.assertIn("config autoconnect 'auto'", migrated_content)
        self.assertIn("option max_handshake_ms '8000'", migrated_content)
        self.assertIn("option rt_table '4300'", migrated_content)
        self.assertIn("Frankfurt Server", migrated_content)

    def test_idempotency_ucode(self):
        """Test migration idempotency: running migration twice is a no-op on v2."""
        if not self.has_ucode:
            self.skipTest("ucode runtime not available")

        script = f"""
        import * as cfg from 'geovpn.config';
        let r1 = cfg.migrate_v1_to_v2('{self.conf_dir}', '{self.backup_dir}');
        let r2 = cfg.migrate_v1_to_v2('{self.conf_dir}', '{self.backup_dir}');
        print(sprintf('%J', {{ r1: r1, r2: r2 }}));
        """
        proc = subprocess.run([self.ucode_bin, '-L', self.lib_path, '-e', script], capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('"already version 2', proc.stdout)

        backups = [f for f in os.listdir(self.backup_dir) if f.startswith('geovpn.v1.')]
        self.assertEqual(len(backups), 1, "No extra backup should be created on second run")

    def test_rollback_ucode(self):
        """Test rollback_migration in ucode: restores v1 content from newest backup."""
        if not self.has_ucode:
            self.skipTest("ucode runtime not available")

        script = f"""
        import * as cfg from 'geovpn.config';
        cfg.migrate_v1_to_v2('{self.conf_dir}', '{self.backup_dir}');
        // Simulate changes in v2
        let r = cfg.rollback_migration('{self.conf_dir}', '{self.backup_dir}');
        print(sprintf('%J', r));
        """
        proc = subprocess.run([self.ucode_bin, '-L', self.lib_path, '-e', script], capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('"ok":true', proc.stdout.replace(' ', ''))

        with open(self.config_file, 'r', encoding='utf-8') as f:
            restored_content = f.read()
        self.assertEqual(restored_content, self.v1_sample)

    def test_prepare_downgrade_ucode(self):
        """Test prepare_downgrade in ucode: handles active profile check and resets version to 1."""
        if not self.has_ucode:
            self.skipTest("ucode runtime not available")

        # Write a v2 config with a non-openvpn active profile
        v2_with_wg = """config main 'main'
	option config_version '2'
	option active_profile 'p_wg'

config profile 'p_ovpn'
	option proto 'openvpn'
	option name 'OpenVPN Fallback'
	option enabled '1'

config profile 'p_wg'
	option proto 'wireguard'
	option name 'WireGuard Tunnel'
	option enabled '1'
"""
        with open(self.config_file, 'w', encoding='utf-8') as f:
            f.write(v2_with_wg)

        script = f"""
        import * as cfg from 'geovpn.config';
        let r = cfg.prepare_downgrade('{self.conf_dir}');
        print(sprintf('%J', r));
        """
        proc = subprocess.run([self.ucode_bin, '-L', self.lib_path, '-e', script], capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)

        with open(self.config_file, 'r', encoding='utf-8') as f:
            content = f.read()
        self.assertIn("option config_version '1'", content)
        # active_profile should have been switched away from wireguard to openvpn
        self.assertIn("option active_profile 'p_ovpn'", content)

    def test_91_geovpn_migrate_shell_script(self):
        """Test /etc/uci-defaults/91-geovpn-migrate shell execution directly."""
        env = os.environ.copy()
        env['PATH'] = f"{os.path.join(self.repo_root, 'tools', 'bin')}:{env.get('PATH', '')}"
        env['CONFIG_FILE'] = self.config_file
        env['BACKUP_DIR'] = self.backup_dir

        # Run migration
        uci_check = subprocess.run([os.path.join(self.repo_root, 'tools', 'bin', 'uci')], capture_output=True)
        if uci_check.returncode == 127:
            self.skipTest("uci binary not available in test environment")

        proc = subprocess.run(['/bin/sh', self.script_path, 'migrate'], env=env, capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, f"Script failed: {proc.stderr}")

        with open(self.config_file, 'r', encoding='utf-8') as f:
            content = f.read()
        self.assertIn("option config_version '2'", content)
        self.assertIn("option proto 'openvpn'", content)
        self.assertIn("config test 'test'", content)

        # Run rollback
        proc_rb = subprocess.run(['/bin/sh', self.script_path, '--rollback'], env=env, capture_output=True, text=True)
        self.assertEqual(proc_rb.returncode, 0, f"Rollback failed: {proc_rb.stderr}")

        with open(self.config_file, 'r', encoding='utf-8') as f:
            restored = f.read()
        self.assertEqual(restored, self.v1_sample)

    def test_cli_migrate_and_rollback_commands(self):
        """Test geovpn CLI migrate and rollback subcommands."""
        if not self.has_ucode:
            self.skipTest("ucode runtime not available")

        env = os.environ.copy()
        env['PATH'] = f"{os.path.join(self.repo_root, 'tools', 'bin')}:{env.get('PATH', '')}"
        env['CONFIG_FILE'] = self.config_file
        env['BACKUP_DIR'] = self.backup_dir

        # 1. Test CLI version
        proc = subprocess.run([self.ucode_bin, '-L', self.lib_path, '-e',
            'import { main } from "geovpn.cli"; exit(main(["version"]));'], capture_output=True, text=True, env=env)
        self.assertEqual(proc.returncode, 0)
        self.assertIn("GeoVPN", proc.stdout)

        # 2. Test CLI migrate
        proc_m = subprocess.run([self.ucode_bin, '-L', self.lib_path, '-e',
            'import { main } from "geovpn.cli"; exit(main(["migrate"]));'], capture_output=True, text=True, env=env)
        self.assertEqual(proc_m.returncode, 0, f"CLI migrate failed: {proc_m.stderr}")
        with open(self.config_file, 'r', encoding='utf-8') as f:
            c_migrated = f.read()
        self.assertIn("option config_version '2'", c_migrated)
        self.assertIn("option proto 'openvpn'", c_migrated)

        # 3. Test CLI rollback
        proc_r = subprocess.run([self.ucode_bin, '-L', self.lib_path, '-e',
            'import { main } from "geovpn.cli"; exit(main(["rollback"]));'], capture_output=True, text=True, env=env)
        self.assertEqual(proc_r.returncode, 0, f"CLI rollback failed: {proc_r.stderr}")
        with open(self.config_file, 'r', encoding='utf-8') as f:
            c_rolled = f.read()
        self.assertEqual(c_rolled, self.v1_sample)

        # 4. Migrate again then test CLI prepare-downgrade
        subprocess.run([self.ucode_bin, '-L', self.lib_path, '-e',
            'import { main } from "geovpn.cli"; exit(main(["migrate"]));'], capture_output=True, text=True, env=env)
        proc_d = subprocess.run([self.ucode_bin, '-L', self.lib_path, '-e',
            'import { main } from "geovpn.cli"; exit(main(["prepare-downgrade"]));'], capture_output=True, text=True, env=env)
        self.assertEqual(proc_d.returncode, 0, f"CLI prepare-downgrade failed: {proc_d.stderr}")
        with open(self.config_file, 'r', encoding='utf-8') as f:
            c_down = f.read()
        self.assertIn("option config_version '1'", c_down)

    def test_keep_settings_sysupgrade_completeness(self):
        """Assert keep.d/geovpn has credentials and backup paths (FR-45 / §8.1)."""
        keep_path = os.path.join(self.repo_root, 'openwrt', 'geovpn-core', 'files', 'lib/upgrade/keep.d/geovpn')
        with open(keep_path, 'r', encoding='utf-8') as f:
            lines = [l.strip() for l in f.readlines() if l.strip()]
        self.assertIn('/etc/geovpn/credentials', lines)
        self.assertIn('/etc/geovpn/backup', lines)
        self.assertIn('/etc/config/geovpn', lines)
        self.assertIn('/etc/geovpn/profiles', lines)

    def test_windscribe_n1_n2_keepalive_fix(self):
        """Assert N1/N2 keepalive fix: ping-exit converts to ping-restart, keepalive suppressed (AT-26)."""
        if not self.has_ucode:
            self.skipTest("ucode runtime not available")

        # Windscribe shaped profile with ping 10 and ping-exit 60
        ovpn_content = """client
dev tun
proto udp
remote dallas.windscribe.com 443
resolv-retry infinite
nobind
persist-key
cipher AES-256-GCM
ncp-ciphers AES-256-GCM:AES-256-CBC
auth SHA512
remote-cert-tls server
verify-x509-name dallas.windscribe.com name
auth-user-pass
ping 10
ping-exit 60
explicit-exit-notify 1
<ca>
-----BEGIN CERTIFICATE-----
MIIB/zCCAaagAwIBAgIJAP
-----END CERTIFICATE-----
</ca>
"""
        script = f"""
        import * as parse from 'geovpn.ovpn_parse';
        import * as render from 'geovpn.ovpn_render';
        let res = parse.parse_ovpn({repr(ovpn_content)}, 'Windscribe Dallas');
        let rendered = render.render_ovpn(res.profile, null, {{ tun_dev: 'geovpn0' }});
        print(rendered);
        """
        proc = subprocess.run([self.ucode_bin, '-L', self.lib_path, '-e', script], capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        out = proc.stdout

        # N1: ping-exit 60 -> ping-restart 60
        self.assertIn("ping-restart 60\n", out)
        self.assertNotIn("ping-exit", out)
        self.assertIn("ping 10\n", out)
        # N2: Default 'keepalive 10 60' must NOT be emitted when ping options present
        self.assertNotIn("keepalive", out)
        # explicit-exit-notify emitted
        self.assertIn("explicit-exit-notify 1\n", out)

    def test_driver_common_contract(self):
        """Test drivers/common.uc lifecycle interface dispatchers and context builder."""
        if not self.has_ucode:
            self.skipTest("ucode runtime not available")

        script = f"""
        import * as drv_common from 'geovpn.drivers.common';
        let ctx = drv_common.create_context('active', 'p11111111', {{ proto: 'openvpn', dev: 'geovpn0', table: 4200 }});
        assert(ctx.proto == 'openvpn', 'proto set');
        assert(ctx.table == 4200, 'table set');

        let drivers = drv_common.list_drivers();
        assert(drivers.openvpn != null, 'openvpn driver listed');

        let val = drv_common.validate({{ name: 'T', remotes: ['vpn.example.com 1194 udp'] }}, {{}});
        assert(val.errors != null, 'validate returned');

        let eps = drv_common.endpoints({{ remotes: ['1.2.3.4 1194 udp', 'vpn.example.com 443 tcp'] }});
        assert(length(eps) == 2, 'two endpoints');
        assert(eps[0].ips[0] == '1.2.3.4', 'ip extracted directly');

        let f = drv_common.facts(ctx);
        assert(f != null && f.dev == 'geovpn0' && f.proto == 'openvpn', 'facts returned');

        print('OK');
        """
        proc = subprocess.run([self.ucode_bin, '-L', self.lib_path, '-e', script], capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('OK', proc.stdout)

    def test_uci_profile_remote_and_remotes_symmetry(self):
        """Test that profile with .remote (from UCI) renders remote lines and populates endpoints."""
        if not self.has_ucode:
            self.skipTest("ucode runtime not available")

        script = f"""
        import * as drv from 'geovpn.drivers.openvpn';
        let p_uci = {{
            name: 'Frankfurt',
            proto: 'openvpn',
            remote: ['de.example.com 1194 udp', '198.51.100.1 443 tcp']
        }};
        let eps = drv.endpoints(p_uci);
        assert(length(eps) == 2, 'endpoints parsed from .remote');
        assert(eps[1].ips[0] == '198.51.100.1', 'ip extracted from second remote');

        let rendered = drv.render_ovpn(p_uci, null, {{ tun_dev: 'geovpn0' }});
        assert(index(rendered, 'remote de.example.com 1194 udp') != -1, 'remote 1 rendered');
        assert(index(rendered, 'remote 198.51.100.1 443 tcp') != -1, 'remote 2 rendered');

        print('OK');
        """
        proc = subprocess.run([self.ucode_bin, '-L', self.lib_path, '-e', script], capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('OK', proc.stdout)

    def test_shell_fallback_no_ucode(self):
        """Test 91-geovpn-migrate execution when ucode binary is completely absent from PATH."""
        system_path = os.environ.get("PATH", "")
        filtered_path = ":".join([p for p in system_path.split(":") if not os.path.exists(os.path.join(p, "ucode"))])
        env = {
            "PATH": f"{os.path.join(self.repo_root, 'tools', 'bin')}:{filtered_path}",
            "CONFIG_FILE": self.config_file,
            "BACKUP_DIR": self.backup_dir
        }

        uci_check = subprocess.run([os.path.join(self.repo_root, 'tools', 'bin', 'uci')], capture_output=True)
        if uci_check.returncode == 127:
            self.skipTest("uci binary not available in test environment")

        # Migrate
        proc_m = subprocess.run(['/bin/sh', self.script_path, 'migrate'], env=env, capture_output=True, text=True)
        self.assertEqual(proc_m.returncode, 0, f"Shell fallback migrate failed: {proc_m.stderr}")
        with open(self.config_file, 'r', encoding='utf-8') as f:
            c_mig = f.read()
        self.assertIn("option config_version '2'", c_mig)

        # Rollback
        proc_r = subprocess.run(['/bin/sh', self.script_path, '--rollback'], env=env, capture_output=True, text=True)
        self.assertEqual(proc_r.returncode, 0, f"Shell fallback rollback failed: {proc_r.stderr}")
        with open(self.config_file, 'r', encoding='utf-8') as f:
            c_roll = f.read()
        self.assertEqual(c_roll, self.v1_sample)


if __name__ == '__main__':
    unittest.main()
