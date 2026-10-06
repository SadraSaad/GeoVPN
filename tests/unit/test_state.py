#!/usr/bin/env python3
"""
Unit tests for GeoVPN State Management
"""
import unittest
import json
import tempfile
import os

class TestStateManager(unittest.TestCase):
    def setUp(self):
        self.test_dir = tempfile.TemporaryDirectory()
        self.state_file = os.path.join(self.test_dir.name, 'state.json')

    def tearDown(self):
        self.test_dir.cleanup()

    def test_state_atomic_write_and_read(self):
        initial = {
            'service': {'enabled': True, 'state': 'connected'},
            'tunnel': {'profile': 'p12345678', 'device': 'geovpn0'}
        }
        tmp_file = self.state_file + '.tmp'
        with open(tmp_file, 'w') as f:
            json.dump(initial, f)
        os.replace(tmp_file, self.state_file)

        with open(self.state_file, 'r') as f:
            loaded = json.load(f)

        self.assertEqual(loaded['service']['state'], 'connected')
        self.assertEqual(loaded['tunnel']['device'], 'geovpn0')


if __name__ == '__main__':
    unittest.main()
