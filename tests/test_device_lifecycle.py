"""Hardware-free regressions; run with python3 -m unittest discover -s tests."""
import runpy
import unittest
from pathlib import Path
from types import SimpleNamespace as NS
from unittest.mock import Mock, patch


backend = runpy.run_path(str(Path(__file__).resolve().parents[1] / "bin/logi"))
Index, Daemon = backend["Index"], backend["Daemon"]


def entry(path="/dev/hidraw-headset", settings=None, receiver=None):
    return {"key": "pro-x", "via": "USB", "settings": settings or [],
            "dev": NS(path=path, receiver=receiver, kind="headset",
                      handle=Mock(), low_level=Mock())}


class LifecycleTests(unittest.TestCase):
    def rebuild(self, monitored=True, removed=False, new_path="/dev/hidraw-headset"):
        index = Index()
        old = entry(settings=["sidetone"])
        fresh = entry(path=new_path)
        index.entries = [old]
        index.hotplug_monitored = monitored
        if removed:
            index.device_removed(old["dev"].path)
        with patch.dict(Index.rebuild.__globals__, discover=lambda: [fresh], rgb_power=None):
            index.rebuild()
        return index, old, fresh

    def test_rescan_keeps_off_headset_controls(self):
        index, old, _ = self.rebuild()
        self.assertIs(index.entries[0], old)
        self.assertFalse(index.incomplete)

    def test_removed_and_reused_node_discards_old_handle(self):
        index, _, fresh = self.rebuild(removed=True)
        self.assertIs(index.entries[0], fresh)
        self.assertTrue(index.incomplete)
        self.assertEqual(index._removed_paths, {})

    def test_changed_path_discards_old_handle(self):
        index, _, fresh = self.rebuild(new_path="/dev/hidraw-new")
        self.assertIs(index.entries[0], fresh)

    def test_no_monitor_discards_direct_handle(self):
        index, _, fresh = self.rebuild(monitored=False)
        self.assertIs(index.entries[0], fresh)

    def test_dropped_device_releases_its_handle(self):
        Device = backend["hid_device"].Device
        index = Index()
        old = entry(settings=["sidetone"])
        dev = old["dev"]
        handle = dev.handle
        Device.instances.append(dev)
        index.entries = [old]
        index.hotplug_monitored = True
        index.device_removed(dev.path)
        with patch.dict(Index.rebuild.__globals__, discover=lambda: [entry()], rgb_power=None):
            index.rebuild()
        leaked = dev in Device.instances
        while dev in Device.instances:
            Device.instances.remove(dev)
        self.assertIsNone(dev.handle)
        dev.low_level.close.assert_called_once_with(handle)
        self.assertFalse(leaked)

    def test_discover_releases_fold_loser(self):
        discover = backend["discover"]
        Device = backend["hid_device"].Device
        a = NS(path="/dev/hidraw-a", receiver=None, kind="headset", name="Pro X",
               bluetooth=False, settings=["sidetone"], handle=Mock(), low_level=Mock())
        b = NS(path="/dev/hidraw-b", receiver=None, kind="headset", name="Pro X",
               bluetooth=False, settings=["sidetone"], handle=Mock(), low_level=Mock())
        Device.instances += [a, b]
        try:
            with patch.dict(discover.__globals__, _receivers_and_devices=lambda: iter([a, b])):
                got = discover()
            self.assertEqual(len(got), 1)
            self.assertIs(got[0]["dev"], a)
            self.assertIsNone(b.handle)
            self.assertNotIn(b, Device.instances)
        finally:
            for d in (a, b):
                while d in Device.instances:
                    Device.instances.remove(d)

    def test_receiver_path_and_cached_arming(self):
        dev = NS(path=None, receiver=NS(path="/dev/hidraw-bolt"), kind="keyboard",
                 number=1, name="MX Keys S", online=True)
        daemon = Daemon()
        daemon.index.entries = [{"key": "mx-keys-s", "dev": dev}]
        daemon.arm = Mock()
        with patch.dict(Daemon.arm_easy_switch.__globals__, feature_index=lambda *args: 3,
                        is_online=Mock(side_effect=AssertionError("unexpected ping"))):
            daemon.arm_easy_switch()
        daemon.arm.assert_called_once_with(dev, "/dev/hidraw-bolt")
        daemon.arm.reset_mock()
        with patch.dict(Daemon.arm_easy_switch.__globals__, feature_index=lambda *args: None):
            daemon.arm_easy_switch()
        daemon.arm.assert_not_called()
        # solaar caches a feature the device lacks as False, not None.
        with patch.dict(Daemon.arm_easy_switch.__globals__, feature_index=lambda *args: False):
            daemon.arm_easy_switch()
            daemon.arm.assert_not_called()
            self.assertIsNone(Daemon().arm(dev, "/dev/hidraw-bolt"))
        self.assertFalse(Daemon().arm(dev, None))

    def test_dropped_entry_ping_does_not_poison_the_cache(self):
        # A rebuild can drop an entry while its ping is in flight and close
        # the fd under it; that failure belongs to the dead handle and must
        # not mark the fresh entry now owning the key unreachable.
        daemon = Daemon()
        daemon.index.entries = [entry()]
        clock = NS(monotonic=backend["time"].monotonic,
                   sleep=Mock(side_effect=StopIteration))

        def drop_mid_ping(dev):
            daemon.index.entries = [entry()]  # fresh entry, same key
            return False

        reach_globals = Daemon.watch_reach.__globals__
        with patch.dict(reach_globals, is_online=drop_mid_ping, time=clock):
            self.assertRaises(StopIteration, daemon.watch_reach)
        self.assertNotIn("pro-x", daemon.reachable)
        # The same write lands when the entry survives the sweep.
        with patch.dict(reach_globals, is_online=Mock(return_value=True), time=clock):
            self.assertRaises(StopIteration, daemon.watch_reach)
        self.assertTrue(daemon.reachable["pro-x"][0])

    def test_silent_device_stops_being_incomplete(self):
        index = Index()
        with patch.dict(Index.rebuild.__globals__, discover=lambda: [entry()], rgb_power=None):
            index.rebuild()
        self.assertTrue(index.incomplete)  # just went silent: may be mid-connect
        index._empty_since["/dev/hidraw-headset"] -= 31
        with patch.dict(Index.rebuild.__globals__, discover=lambda: [entry()], rgb_power=None):
            index.rebuild()
        self.assertFalse(index.incomplete)  # off all along: no more retries

    def test_receiver_source_is_not_moved_again(self):
        dev = NS(path=None, receiver=NS(path="/dev/hidraw-bolt"), kind="keyboard",
                 number=1, name="MX Keys S", online=True)
        daemon = Daemon()
        daemon.index.entries = [{"key": "mx-keys-s", "dev": dev, "via": "Bolt Receiver"}]
        daemon.mark_away = Mock()
        with patch.dict(Daemon.follow_to.__globals__,
                        is_online=Mock(side_effect=AssertionError("source was not excluded")), log=Mock()):
            daemon.follow_to("mx-keys-s", ("/dev/hidraw-bolt", 1), 2)
        daemon.mark_away.assert_called_once()

    def test_receiver_reports_filter_sibling_slots(self):
        parse = backend["host_switch_target"]
        self.assertEqual(parse(bytes([0x11, 1, 3, 0, 1, 2]), 3, 1), 2)
        self.assertIsNone(parse(bytes([0x11, 2, 3, 0, 1, 2]), 3, 1))


if __name__ == "__main__":
    unittest.main()
