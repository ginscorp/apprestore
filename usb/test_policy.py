"""Offline policy tests; the all-zero UDID is a deliberately synthetic placeholder."""
import socket
import tempfile
import unittest
import zipfile
import plistlib
from pathlib import Path
import bridge


class PolicyTests(unittest.TestCase):
    def test_no_listener_or_udp(self):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            with self.assertRaises(PermissionError):sock.bind(("127.0.0.1",0))
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            with self.assertRaises(PermissionError):sock.sendto(b"fixture",("127.0.0.1",9))
        first,second=socket.socketpair()
        try:
            first.send(b"fixture");self.assertEqual(second.recv(7),b"fixture")
        finally:first.close();second.close()

    def test_no_internet(self):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            with self.assertRaises(PermissionError):
                sock.connect(("127.0.0.1", 443))

    def test_no_arbitrary_socket(self):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            with self.assertRaises(PermissionError):
                sock.connect("/private/tmp/unrelated.sock")

    def test_udid(self):
        self.assertFalse(bridge.valid_udid("; shell"))
        self.assertTrue(bridge.valid_udid('00000000-0000000000000000'))

    def test_no_arbitrary_package(self):
        self.assertIsNone(bridge.valid_package("/etc/passwd"))
        with tempfile.TemporaryDirectory(prefix="apprestore-session-") as tmp:
            package = Path(tmp) / "application.ipa"
            with zipfile.ZipFile(package, "w") as z:
                z.writestr("Payload/Test.app/Info.plist", plistlib.dumps({"CFBundleExecutable":"Test"}))
                z.writestr("Payload/Test.app/Test", b"synthetic")
            self.assertIsNone(bridge.valid_package(str(package)))
            with zipfile.ZipFile(package, "a") as z:
                z.writestr("Payload/Test.app/SC_Info/Test.sinf", b"synthetic_license")
            self.assertEqual(bridge.valid_package(str(package)), package)


if __name__ == "__main__":
    unittest.main()
