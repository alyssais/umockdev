/*
 * test-umockdev.vala
 *
 * Copyright (C) 2012 Canonical Ltd.
 * Author: Martin Pitt <martin.pitt@ubuntu.com>
 *
 * umockdev is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * umockdev is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; If not, see <http://www.gnu.org/licenses/>.
 */

using Assertions;

void
t_testbed_empty ()
{
  var tb = new UMockdev.Testbed ();
  assert (tb != null);
  var enumerator = new GUdev.Enumerator (new GUdev.Client(null));
  var devices = enumerator.execute ();

  assert_cmpuint (devices.length(), Op.EQ, 0);
}

void
t_testbed_add_device ()
{
  var tb = new UMockdev.Testbed ();

  string syspath = tb.add_devicev ("usb",
                                   "extkeyboard1",
                                   null,
                                   { "idVendor", "0815", "idProduct", "AFFE" },
                                   { "ID_INPUT", "1", "ID_INPUT_KEYBOARD", "1" });
  assert_cmpstr (syspath, Op.EQ, "/sys/devices/extkeyboard1");

  var enumerator = new GUdev.Enumerator (new GUdev.Client(null));
  var devices = enumerator.execute ();
  assert_cmpuint (devices.length(), Op.EQ, 1);

  GUdev.Device device = devices.nth_data(0);
  assert_cmpstr (device.get_name (), Op.EQ, "extkeyboard1");
  assert_cmpstr (device.get_sysfs_path (), Op.EQ, "/sys/devices/extkeyboard1");
  assert_cmpstr (device.get_subsystem (), Op.EQ, "usb");
  assert_cmpstr (device.get_sysfs_attr ("idVendor"), Op.EQ, "0815");
  assert_cmpstr (device.get_sysfs_attr ("idProduct"), Op.EQ, "AFFE");
  assert_cmpstr (device.get_sysfs_attr ("noSuchAttr"), Op.EQ, null);
  assert_cmpstr (device.get_property ("DEVPATH"), Op.EQ, "/devices/extkeyboard1");
  assert_cmpstr (device.get_property ("SUBSYSTEM"), Op.EQ, "usb");
  assert_cmpstr (device.get_property ("ID_INPUT"), Op.EQ, "1");
  assert_cmpstr (device.get_property ("ID_INPUT_KEYBOARD"), Op.EQ, "1");
  assert_cmpstr (device.get_property ("NO_SUCH_PROP"), Op.EQ, null);
}

void
t_usbfs_ioctl_static ()
{
  var tb = new UMockdev.Testbed ();

  tb.add_from_string ("""P: /devices/mycam
N: 001
E: SUBSYSTEM=usb
""");

  int fd = Posix.open ("/dev/001", Posix.O_RDWR, 0);
  assert_cmpint (fd, Op.GE, 0);

  int i = 1;
  assert_cmpint (Posix.ioctl (fd, Ioctl.USBDEVFS_CLAIMINTERFACE, ref i), Op.EQ, 0);
  assert_cmpint (Posix.errno, Op.EQ, 0);
  assert_cmpint (Posix.ioctl (fd, Ioctl.USBDEVFS_GETDRIVER, ref i), Op.EQ, -1);
  assert_cmpint (Posix.errno, Op.EQ, Posix.ENODATA);
  Posix.errno = 0;

  /* no ioctl tree loaded */
  var ci = Ioctl.usbdevfs_connectinfo();
  assert_cmpint (Posix.ioctl (fd, Ioctl.USBDEVFS_CONNECTINFO, ref ci), Op.EQ, -1);
  assert_cmpint (Posix.errno, Op.EQ, Posix.ENOTTY);
  errno = 0;

  Posix.close (fd);
}

void
t_usbfs_ioctl_tree ()
{
  var tb = new UMockdev.Testbed ();
  tb.add_from_string ("""P: /devices/mycam
N: 001
E: SUBSYSTEM=usb
""");

  // add simple ioctl tree
  string test_tree = """USBDEVFS_CONNECTINFO 11 0
USBDEVFS_REAPURB 1 129 -1 0 4 4 0 9902AAFF
USBDEVFS_CONNECTINFO 12 1
""";

  string tmppath;
  int fd = FileUtils.open_tmp ("test_ioctl_tree.XXXXXX", out tmppath);
  assert_cmpint ((int) Posix.write (fd, test_tree, test_tree.length), Op.GT, 20);

  // ioctl emulation does not get in the way of non-/dev fds
  int i = 1;
  assert_cmpint (Posix.ioctl (fd, Ioctl.USBDEVFS_CLAIMINTERFACE, ref i), Op.EQ, -1);
  assert_cmpint (Posix.errno, Op.EQ, Posix.ENOTTY);

  Posix.close (fd);
  tb.load_ioctl ("/dev/001", tmppath);
  FileUtils.unlink (tmppath);

  fd = Posix.open ("/dev/001", Posix.O_RDWR, 0);
  assert_cmpint (fd, Op.GE, 0);

  // static ioctl
  assert_cmpint (Posix.ioctl (fd, Ioctl.USBDEVFS_CLAIMINTERFACE, ref i), Op.EQ, 0);
  assert_cmpint (Posix.errno, Op.EQ, 0);

  // loaded ioctl
  var ci = Ioctl.usbdevfs_connectinfo();
  assert_cmpint (Posix.ioctl (fd, Ioctl.USBDEVFS_CONNECTINFO, ref ci), Op.EQ, 0);
  assert_cmpint (Posix.errno, Op.EQ, 0);
  assert_cmpuint (ci.devnum, Op.EQ, 11);
  assert_cmpuint (ci.slow, Op.EQ, 0);

  /* loaded ioctl: URB */
  var urb_buffer = new uint8[4];
  Ioctl.usbdevfs_urb urb = {1, 129, 0, 0, urb_buffer, 4, 0};
  assert_cmpint (Posix.ioctl (fd, Ioctl.USBDEVFS_SUBMITURB, ref urb), Op.EQ, 0);
  assert_cmpint (Posix.errno, Op.EQ, 0);
  assert_cmpuint (urb.status, Op.EQ, 0);
  assert_cmpint (urb_buffer[0], Op.EQ, 0);

  Ioctl.usbdevfs_urb* urb_reap = null;
  assert_cmpint (Posix.ioctl (fd, Ioctl.USBDEVFS_REAPURB, ref urb_reap), Op.EQ, 0);
  assert_cmpint (Posix.errno, Op.EQ, 0);
  assert (urb_reap == &urb);
  assert_cmpint (urb.status, Op.EQ, -1);
  assert_cmpuint (urb.buffer[0], Op.EQ, 0x99);
  assert_cmpuint (urb.buffer[1], Op.EQ, 0x02);
  assert_cmpuint (urb.buffer[2], Op.EQ, 0xAA);
  assert_cmpuint (urb.buffer[3], Op.EQ, 0xFF);

  // open the device a second time
  int fd2 = Posix.open ("/dev/001", Posix.O_RDWR, 0);
  assert_cmpint (fd2, Op.GE, 0);

  // exercise ioctl on fd2, should iterate from beginning
  ci.devnum = 99;
  ci.slow = 99;
  assert_cmpint (Posix.ioctl (fd2, Ioctl.USBDEVFS_CONNECTINFO, ref ci), Op.EQ, 0);
  assert_cmpint (Posix.errno, Op.EQ, 0);
  assert_cmpuint (ci.devnum, Op.EQ, 11);
  assert_cmpuint (ci.slow, Op.EQ, 0);

  // should still work on first fd, and continue with original tree state
  ci.devnum = 99;
  ci.slow = 99;
  assert_cmpint (Posix.ioctl (fd, Ioctl.USBDEVFS_CONNECTINFO, ref ci), Op.EQ, 0);
  assert_cmpint (Posix.errno, Op.EQ, 0);
  assert_cmpuint (ci.devnum, Op.EQ, 12);
  assert_cmpuint (ci.slow, Op.EQ, 1);

  Posix.close (fd);
}

int
main (string[] args)
{
  Test.init (ref args);
  /* tests for mocking /sys */
  Test.add_func ("/umockdev-testbed-vala/empty", t_testbed_empty);
  Test.add_func ("/umockdev-testbed-vala/add_devicev", t_testbed_add_device);

  /* tests for mocking ioctls */
  Test.add_func ("/umockdev-testbed-vala/usbfs_ioctl_static", t_usbfs_ioctl_static);
  Test.add_func ("/umockdev-testbed-vala/usbfs_ioctl_tree", t_usbfs_ioctl_tree);
  return Test.run();
}
