#!/usr/bin/env python3
"""
Unit tests for GeoVPN Policy Routing & Undo Journal Logic
"""
import unittest

def build_route_commands(main_cfg):
    prio = str(main_cfg.get('rule_priority', 700))
    table = str(main_cfg.get('rt_table', 4200))
    shift = int(main_cfg.get('mark_shift', 24))
    vpn_mark = f"0x{(1 << shift):08x}"
    mark_mask = f"0x{(0xf << shift):08x}"
    mark_spec = f"{vpn_mark}/{mark_mask}"
    kill_switch = bool(main_cfg.get('kill_switch') in (1, '1', True))

    commands = [
        ['ip', '-4', 'rule', 'add', 'priority', prio, 'fwmark', mark_spec, 'lookup', table],
        ['ip', '-6', 'rule', 'add', 'priority', prio, 'fwmark', mark_spec, 'lookup', table]
    ]

    undo = [
        ['ip', '-6', 'rule', 'del', 'priority', prio],
        ['ip', '-4', 'rule', 'del', 'priority', prio]
    ]

    if kill_switch:
        commands.append(['ip', '-4', 'route', 'replace', 'unreachable', 'default', 'table', table, 'metric', '4000'])
        commands.append(['ip', '-6', 'route', 'replace', 'unreachable', 'default', 'table', table, 'metric', '4000'])
        undo.insert(0, ['ip', '-6', 'route', 'del', 'unreachable', 'default', 'table', table, 'metric', '4000'])
        undo.insert(0, ['ip', '-4', 'route', 'del', 'unreachable', 'default', 'table', table, 'metric', '4000'])

    return commands, undo


class TestRoute(unittest.TestCase):
    def test_route_commands_kill_switch_on(self):
        cfg = {'rule_priority': 700, 'rt_table': 4200, 'mark_shift': 24, 'kill_switch': True}
        cmds, undo = build_route_commands(cfg)

        self.assertEqual(cmds[0], ['ip', '-4', 'rule', 'add', 'priority', '700', 'fwmark', '0x01000000/0x0f000000', 'lookup', '4200'])
        self.assertEqual(cmds[2], ['ip', '-4', 'route', 'replace', 'unreachable', 'default', 'table', '4200', 'metric', '4000'])
        self.assertEqual(len(undo), 4)

    def test_route_commands_kill_switch_off(self):
        cfg = {'rule_priority': 700, 'rt_table': 4200, 'mark_shift': 24, 'kill_switch': False}
        cmds, undo = build_route_commands(cfg)

        self.assertEqual(len(cmds), 2)
        self.assertEqual(len(undo), 2)


if __name__ == '__main__':
    unittest.main()
