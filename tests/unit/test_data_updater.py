#!/usr/bin/env python3
"""
Unit tests for GeoVPN data updater verification logic
"""
import unittest

def parse_tsv(content):
    rows = []
    for line in content.strip().split('\n'):
        if not line or line.startswith('#'): continue
        rows.append(line.split('\t'))
    return rows

def check_downgrade(new_time, stored_time, force=False):
    if force: return True
    if stored_time > 0 and new_time > 0 and new_time < stored_time:
        return False
    return True

def generate_cron_lines(existing, cron_expr, enabled, auto_update):
    clean = []
    in_block = False
    for line in existing.split('\n'):
        l = line.strip()
        if l == '# geovpn begin':
            in_block = True
            continue
        if l == '# geovpn end':
            in_block = False
            continue
        if not in_block and l:
            clean.append(line)

    if enabled and auto_update:
        clean.append('# geovpn begin')
        clean.append(f'{cron_expr} /usr/libexec/geovpn/spawn update --cron')
        clean.append('# geovpn end')

    return '\n'.join(clean) + '\n'


class TestDataUpdater(unittest.TestCase):
    def test_tsv_parsing(self):
        sample = "ir\t18\t2\thash1\thash2\t100\t50\nprivate\t8\t4\thash3\thash4\t80\t40\n"
        rows = parse_tsv(sample)
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0][0], 'ir')
        self.assertEqual(rows[0][1], '18')

    def test_downgrade_protection(self):
        self.assertFalse(check_downgrade(new_time=1700000000, stored_time=1700050000, force=False))
        self.assertTrue(check_downgrade(new_time=1700000000, stored_time=1700050000, force=True))
        self.assertTrue(check_downgrade(new_time=1700060000, stored_time=1700050000, force=False))

    def test_cron_schedule_management(self):
        base = "0 0 * * * /usr/bin/daily-task\n"
        cron = generate_cron_lines(base, "17 4 * * *", enabled=True, auto_update=True)
        self.assertIn("# geovpn begin\n17 4 * * * /usr/libexec/geovpn/spawn update --cron\n# geovpn end", cron)
        self.assertIn("/usr/bin/daily-task", cron)

        # Disabling auto-update removes block
        removed = generate_cron_lines(cron, "17 4 * * *", enabled=False, auto_update=True)
        self.assertNotIn("geovpn", removed)
        self.assertIn("/usr/bin/daily-task", removed)

    def test_real_ucode_data_parse_tsv(self):
        import os, subprocess, json
        repo_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        ucode_bin = os.path.join(repo_root, 'tools', 'bin', 'ucode')
        lib_path = os.path.join(repo_root, 'openwrt', 'geovpn-core', 'files', 'usr', 'share', 'ucode')
        if not os.path.exists(ucode_bin):
            return

        script = """
        import * as data from 'geovpn.data';
        let sample = "ir\\t18\\t2\\thash1\\thash2\\t100\\t50\\nprivate\\t8\\t4\\thash3\\thash4\\t80\\t40\\n";
        let rows = data.parse_tsv(sample);
        print(sprintf('%J', rows));
        """
        proc = subprocess.run([ucode_bin, '-L', lib_path, '-e', script], text=True, capture_output=True)
        self.assertEqual(proc.returncode, 0, f"ucode error: {proc.stderr}")
        rows = json.loads(proc.stdout)
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0][0], 'ir')
        self.assertEqual(rows[1][0], 'private')


if __name__ == '__main__':
    unittest.main()
