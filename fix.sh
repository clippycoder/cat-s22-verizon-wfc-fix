#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 cat-s22-verizon-wfc-fix contributors
#
# cat-s22-verizon-wfc-fix — write the SIM's line number into the one modem setting that
# Verizon Wi-Fi calling voice needs (see README.md).
#
# Run it and use the menu: check the setting, enable Wi-Fi calling voice (guided),
# restore a saved backup, or list USB devices for troubleshooting. No flags needed.
#
# The phone's USB diag port must already be open (dial ##3424# on the phone; see README.md).
# This script installs nothing system-wide: it needs python3 and libusb, and puts the one
# Python dependency (pyusb) in a temporary folder that is deleted when it exits.
# macOS and Linux only.
set -euo pipefail

main() {
  command -v python3 >/dev/null 2>&1 || { echo "python3 is required (>= 3.8)." >&2; exit 1; }
  python3 -I -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' \
    || { echo "python3 >= 3.8 is required." >&2; exit 1; }
  { : </dev/tty; } 2>/dev/null \
    || { echo "This tool is interactive: run it in a terminal window." >&2; exit 1; }

  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT

  if ! python3 -I -c 'import usb.core' >/dev/null 2>&1; then
    echo "Installing pyusb into a temporary folder (nothing system-wide)..." >&2
    if ! python3 -I -m pip install --quiet --disable-pip-version-check --target "$tmp/lib" 'pyusb>=1.2,<2' >/dev/null 2>&1; then
      if python3 -m venv "$tmp/venv" >/dev/null 2>&1 \
         && "$tmp/venv/bin/python" -I -m pip install --quiet --disable-pip-version-check 'pyusb>=1.2,<2' >/dev/null 2>&1; then
        PY="$tmp/venv/bin/python"
      else
        echo "Could not install pyusb. Install pip for python3 (e.g. 'sudo apt install python3-pip' or 'brew install python') and retry." >&2
        exit 1
      fi
    fi
  fi
  PY=${PY:-python3}

  cat > "$tmp/wfc_fix.py" <<'WFC_FIX_PY_EOF'
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 cat-s22-verizon-wfc-fix contributors
"""Menu-driven tool: read/write one Qualcomm modem EFS item over the phone's USB diag port (no root)."""
import datetime, getpass, glob, os, struct, sys, time

ITEM = "/nv/item_files/ims/qp_ims_service_enablement_config"
ITEM_SIZE = 1024
MDN_START, MDN_END = 0x0E, 0x22            # the 20-byte "NV MDN" string inside the item
QUALCOMM_VID = 0x05C6
DIAG_IFACE = (0xFF, 0xFF, 0x30)            # USB class/subclass/protocol of the DIAG interface
SUBSYS_CMD_F, SUBSYS_FS = 0x4B, 19         # diag "subsystem dispatch" -> EFS2
EFS2_HELLO, EFS2_PUT, EFS2_GET = 0, 38, 39
O_CREAT, O_AUTODIR = 0o100, 0o2000000
BACKUP_GLOB = "cat-s22-wfc-backup-*.bin"
WRITE_STARTED = False                      # set once a write request has been sent
AFTER_WRITE_NOTE = ("The write may or may not have gone through. Choose 1 (check) to see the current state;\n"
                    "undo with 3 (restore) and the backup file saved just before the write.")


class Problem(Exception):
    """A recoverable problem: show the message and go back to the menu."""


# ---------- HDLC framing (what the diag port speaks) ----------
def crc16(data):
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0x8408 if crc & 1 else crc >> 1
    return crc ^ 0xFFFF


def hdlc(payload):
    raw = payload + struct.pack("<H", crc16(payload))
    out = bytearray()
    for b in raw:
        if b in (0x7D, 0x7E):
            out += bytes([0x7D, b ^ 0x20])
        else:
            out.append(b)
    return bytes(out) + b"\x7e"


class Framer:
    """Feed raw bytes, get complete, CRC-checked payloads back."""
    def __init__(self):
        self.buf = b""

    def feed(self, data):
        self.buf += data
        *chunks, self.buf = self.buf.split(b"\x7e")
        for chunk in chunks:
            if not chunk:
                continue
            out, esc = bytearray(), False
            for b in chunk:
                if esc:
                    out.append(b ^ 0x20); esc = False
                elif b == 0x7D:
                    esc = True
                else:
                    out.append(b)
            if len(out) >= 3 and crc16(bytes(out[:-2])) == struct.unpack("<H", out[-2:])[0]:
                yield bytes(out[:-2])


# ---------- EFS2 requests ----------
def req_hello():
    return hdlc(struct.pack("<BBH6I3II", SUBSYS_CMD_F, SUBSYS_FS, EFS2_HELLO, *([0x100000] * 6), 1, 1, 1, 0xFFFFFFFF))


def req_get(path, size, seq):
    pb = path.encode() + b"\0"
    return hdlc(struct.pack("<BBHiiH", SUBSYS_CMD_F, SUBSYS_FS, EFS2_GET, size, len(pb), seq) + pb)


def req_put(path, data, seq):
    pb = path.encode() + b"\0"
    return hdlc(struct.pack("<BBHIiH", SUBSYS_CMD_F, SUBSYS_FS, EFS2_PUT, len(data), O_CREAT | O_AUTODIR, seq) + data + pb)


def parse_efs(body):
    """-> ('hello'|'get'|'put'|'other', seq, errno, data) or None if not an EFS2 reply."""
    if len(body) < 4 or body[0] != SUBSYS_CMD_F or body[1] != SUBSYS_FS:
        return None
    sub = struct.unpack_from("<H", body, 2)[0]
    if sub == EFS2_HELLO:
        return ("hello", 0, 0, b"")
    if sub == EFS2_PUT:
        seq, err = struct.unpack_from("<Hi", body, 4)
        return ("put", seq, err, b"")
    if sub == EFS2_GET:
        nbytes, err, seq = struct.unpack_from("<iiH", body, 4)
        return ("get", seq, err, body[14:14 + max(nbytes, 0)])
    return ("other", 0, 0, b"")


# ---------- USB diag port ----------
class DiagPort:
    def __init__(self, dev, intf):
        import usb.core, usb.util
        self.usb = usb
        self.dev, self.intf = dev, intf
        self.name = "%04x:%04x" % (dev.idVendor, dev.idProduct)
        n = intf.bInterfaceNumber
        try:
            if dev.is_kernel_driver_active(n):
                dev.detach_kernel_driver(n)
        except (NotImplementedError, usb.core.USBError):
            pass
        try:
            usb.util.claim_interface(dev, n)
        except usb.core.USBError as e:
            raise Problem("Could not open the diag port (%s). On Linux try a udev rule or run as root; on macOS make sure no other "
                          "program (e.g. a serial tool) is using it." % e)
        self.ep_out = next(e.bEndpointAddress for e in intf if not e.bEndpointAddress & 0x80)
        self.ep_in = next(e.bEndpointAddress for e in intf if e.bEndpointAddress & 0x80)
        self.framer = Framer()
        self.frames = []
        self.read(100)                                   # drain anything stale

    def write(self, data):
        self.dev.write(self.ep_out, data, timeout=3000)

    def read(self, timeout_ms=300):
        try:
            data = bytes(self.dev.read(self.ep_in, 16384, timeout=timeout_ms))
        except self.usb.core.USBTimeoutError:
            return
        except self.usb.core.USBError as e:
            if getattr(e, "errno", None) in (110, 60):   # timeout on some platforms
                return
            raise Problem("USB error talking to the phone: %s" % e)
        self.frames.extend(self.framer.feed(data))

    def call(self, request, kind, seq=None, timeout=8.0):
        """Send one request, wait for the matching EFS2 reply."""
        self.write(request)
        end = time.time() + timeout
        while time.time() < end:
            while self.frames:
                r = parse_efs(self.frames.pop(0))
                if r and r[0] == kind and (seq is None or r[1] == seq):
                    return r
            self.read()
        raise Problem("No reply from the modem (%s). Is the phone fully booted and the diag port still open? Try again." % kind)

    def close(self):
        try:
            self.usb.util.release_interface(self.dev, self.intf.bInterfaceNumber)
            self.usb.util.dispose_resources(self.dev)
        except Exception:
            pass


def find_diag_ports():
    import usb.core
    out = []
    for dev in usb.core.find(find_all=True, idVendor=QUALCOMM_VID):
        for cfg in dev:
            for intf in cfg:
                if (intf.bInterfaceClass, intf.bInterfaceSubClass, intf.bInterfaceProtocol) == DIAG_IFACE:
                    out.append((dev, intf))
    return out


def libusb_help():
    return ("libusb was not found (pyusb needs it). Install it, then run this tool again:\n"
            "  macOS:          brew install libusb\n"
            "  Debian/Ubuntu:  sudo apt install libusb-1.0-0\n"
            "  Fedora:         sudo dnf install libusb1\n"
            "  Arch:           sudo pacman -S libusb")


def ask(prompt):
    return input(prompt).strip()


def pick_number(prompt, lo, hi):
    while True:
        text = ask(prompt)
        if text.isascii() and text.isdigit() and lo <= int(text) <= hi:
            return int(text)
        print("Please type a number from %d to %d." % (lo, hi))


def confirm(question):
    return ask(question + " [y/N] ").lower() in ("y", "yes")


def connect():
    """Find the phone's diag port (asking which one if several) and open it."""
    import usb.core
    try:
        cands = find_diag_ports()
    except usb.core.NoBackendError:
        raise Problem(libusb_help())
    if not cands:
        raise Problem("No phone with an open USB diag port found.\n"
                      "Open the diag port first (dial ##3424# on the phone, see README.md), then try again.\n"
                      "Menu option 4 shows what the computer can see.")
    pick = 0
    if len(cands) > 1:
        print("More than one diag port is connected:")
        for i, (d, _) in enumerate(cands, 1):
            print("  %d) %04x:%04x (bus %s, address %s)" % (i, d.idVendor, d.idProduct, d.bus, d.address))
        pick = pick_number("Which one is the phone you want to change? ", 1, len(cands)) - 1
    return DiagPort(*cands[pick])


def efs_session(port):
    port.call(req_hello(), "hello")


def efs_read(port):
    err, data = port.call(req_get(ITEM, ITEM_SIZE, 1), "get", 1)[2:]
    if err != 0:
        raise Problem("The modem refused to read %s (errno %d)." % (ITEM, err))
    if len(data) != ITEM_SIZE:
        raise Problem("The item is %d bytes, expected %d: this tool does not apply to this phone. Nothing was changed." % (len(data), ITEM_SIZE))
    return data


def efs_write(port, data):
    global WRITE_STARTED
    WRITE_STARTED = True
    err = port.call(req_put(ITEM, data, 1), "put", 1)[2]
    if err != 0:
        WRITE_STARTED = False
        raise Problem("The modem refused the write (errno %d). Nothing was changed." % err)


# ---------- the item ----------
def mdn_status(item):
    f = item[MDN_START:MDN_END]
    if not any(f):
        return "EMPTY"
    if all(0x30 <= b <= 0x39 or b == 0 for b in f):
        return "digits, length %d" % sum(1 for b in f if b)
    return "non-digit data"


def summary(item):
    flags = struct.unpack_from("<I", item, 4)[0]
    lines = ["NV MDN field   : %s" % mdn_status(item),
             "service flags  : 0x%08x%s" % (flags, "" if flags & 0x13 == 0x13 else "   (WARNING: bits 0, 1 and 4 should be set)"),
             "WFC enabled    : %d%s" % (item[8], "" if item[8] == 1 else "   (turn Wi-Fi calling on in Android settings)")]
    return "\n".join(lines)


def looks_sane(item):
    return len(item) == ITEM_SIZE and item[8] in (0, 1, 2) and struct.unpack_from("<I", item, 4)[0] < 0x10000


def with_number(item, number):
    new = bytearray(item)
    new[MDN_START:MDN_END] = bytes(MDN_END - MDN_START)
    digits = number.encode()
    new[MDN_START:MDN_START + len(digits)] = digits          # NUL padding is already there
    return bytes(new)


def normalize_number(text):
    d = "".join(ch for ch in text if ch in "0123456789")
    if len(d) == 10:
        d = "1" + d
    if len(d) != 11 or d[0] != "1":
        return None
    return d


def save_backup(item):
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    for n in range(100):
        name = "cat-s22-wfc-backup-%s%s.bin" % (stamp, "" if n == 0 else "-%d" % n)
        try:
            fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            continue
        with os.fdopen(fd, "wb") as f:
            f.write(item)
        return name
    raise Problem("Could not create a backup file in the current folder. Nothing was changed.")


# ---------- menu actions ----------
def action_check():
    port = connect()
    try:
        efs_session(port)
        item = efs_read(port)
        print("\ndiag port      : %s" % port.name)
        print(summary(item))
        if not looks_sane(item):
            print("\nWARNING: the item does not look like the expected layout; this tool may not apply to this phone.")
        elif mdn_status(item) == "EMPTY":
            print("\nThe NV MDN field is empty: this is the problem option 2 fixes.")
        else:
            print("\nThe NV MDN field is already set.")
    finally:
        port.close()


def action_enable():
    port = connect()
    try:
        efs_session(port)
        item = efs_read(port)
        print("\ndiag port      : %s" % port.name)
        print(summary(item))
        if not looks_sane(item):
            raise Problem("\nThe item does not look like the expected layout, so nothing will be written.")
        if mdn_status(item) != "EMPTY":
            print("WARNING: the field already holds a value; it will be replaced (a backup is saved first).")
        number = None
        while number is None:
            text = getpass.getpass("\nSIM line number (10 digits, or 1 + 10 digits; input is hidden; empty to cancel): ")
            if not text.strip():
                print("Cancelled. Nothing was changed.")
                return
            number = normalize_number(text)
            if number is None:
                print("That is not a US line number. Try again.")
        new = with_number(item, number)
        if new == item:
            print("\nThe field already holds exactly that number. Nothing to do.")
            return
        print("\nAbout to write a number ending in ...%s (bytes 0x%02x-0x%02x of the item only)." % (number[-4:], MDN_START, MDN_END - 1))
        if not confirm("Continue?"):
            print("Cancelled. Nothing was changed.")
            return
        print("Backup of the current item saved to: %s" % save_backup(item))
        efs_write(port, new)
        if efs_read(port) == new:
            print("VERIFIED: the modem now holds the new value.\n\nNow reboot the phone (hold power, or `adb reboot`) so the modem reloads it.")
        else:
            raise Problem("WARNING: read-back differs from what was written. Undo with option 3 (restore).")
    finally:
        port.close()


def list_backups():
    files = sorted(glob.glob(BACKUP_GLOB), reverse=True)
    rows = []
    for f in files:
        try:
            data = open(f, "rb").read()
        except OSError:
            continue
        rows.append((f, data))
    return rows


def action_restore():
    rows = [(f, d) for f, d in list_backups() if len(d) == ITEM_SIZE]
    print("\nBackups in this folder (%s):" % os.getcwd())
    for i, (f, d) in enumerate(rows, 1):
        print("  %d) %s   [NV MDN: %s]" % (i, f, mdn_status(d)))
    if not rows:
        print("  (none found)")
    print("  p) type a path to a backup file")
    print("  0) cancel")
    while True:
        choice = ask("Choose: ").lower()
        if choice == "0":
            print("Cancelled. Nothing was changed.")
            return
        if choice == "p":
            path = ask("Path to the backup file: ").strip().strip("'\"")
            try:
                data = open(os.path.expanduser(path), "rb").read()
            except OSError as e:
                print("Could not read that file: %s" % e)
                continue
            break
        if choice.isascii() and choice.isdigit() and 1 <= int(choice) <= len(rows):
            data = rows[int(choice) - 1][1]
            break
        print("Please choose one of the listed options.")
    if len(data) != ITEM_SIZE:
        raise Problem("That file is %d bytes; a backup must be exactly %d. Nothing was changed." % (len(data), ITEM_SIZE))
    port = connect()
    try:
        efs_session(port)
        current = efs_read(port)
        print("\nCurrent setting in the phone:\n" + summary(current) + "\n\nBackup file:\n" + summary(data))
        if not confirm("\nWrite the backup over the current setting?"):
            print("Cancelled. Nothing was changed.")
            return
        if data != current:
            print("Backup of the current item saved to: %s" % save_backup(current))
        efs_write(port, data)
        if efs_read(port) != data:
            raise Problem("WARNING: read-back differs from the backup file.")
        print("VERIFIED: the backup is restored.\nReboot the phone so the modem reloads it.")
    finally:
        port.close()


def action_list():
    import usb.core
    try:
        devs = list(usb.core.find(find_all=True))
        diag = {(d.bus, d.address) for d, _ in find_diag_ports()}
    except usb.core.NoBackendError:
        raise Problem(libusb_help())
    print()
    for d in devs:
        mark = "   <-- diag port" if (d.bus, d.address) in diag else ""
        print("  %04x:%04x  (bus %s, address %s)%s" % (d.idVendor, d.idProduct, d.bus, d.address, mark))
    if not diag:
        print("\nNo diag port found. With the diag port open, the phone appears as 05c6:xxxx with an interface of class ff/ff/30.\n"
              "Dial ##3424# on the phone (see README.md), make sure the cable carries data, and try again.")


MENU = """
  1) Check the current setting (read-only)
  2) Enable Wi-Fi calling voice (guided: sets the line number)
  3) Restore a saved backup
  4) Troubleshooting: list USB devices
  5) Quit
"""


def main():
    global WRITE_STARTED
    if not sys.stdin.isatty():
        raise SystemExit("This tool is interactive: run it in a terminal window.")
    print("cat-s22-verizon-wfc-fix")
    print("-----------------------")
    print("Before you start: open the phone's USB diag port (dial ##3424# on the phone) and connect it with a data cable.")
    actions = {"1": action_check, "2": action_enable, "3": action_restore, "4": action_list}
    try:
        while True:
            print(MENU)
            choice = ask("Choose 1-5: ")
            if choice in ("5", "q", "quit", "exit"):
                return
            action = actions.get(choice)
            if action is None:
                print("Please type a number from 1 to 5.")
                continue
            WRITE_STARTED = False
            try:
                action()
            except Problem as e:
                print("\n" + str(e))
                if WRITE_STARTED:
                    print("\n" + AFTER_WRITE_NOTE)
            except KeyboardInterrupt:
                print("\nCancelled. " + (AFTER_WRITE_NOTE if WRITE_STARTED else "Nothing was changed."))
    except (KeyboardInterrupt, EOFError):
        print("\nBye.")


if __name__ == "__main__":
    main()
WFC_FIX_PY_EOF

  # Run with the terminal as stdin so the menu works even when this script is piped from curl/gh.
  PYTHONPATH="$tmp/lib${PYTHONPATH:+:$PYTHONPATH}" "$PY" "$tmp/wfc_fix.py" </dev/tty
}

main
