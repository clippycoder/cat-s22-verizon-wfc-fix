# cat-s22-verizon-wfc-fix

Fixes **Verizon Wi-Fi calling voice** on the **CAT S22 Flip** when the phone shows *"Voice: false"* / refuses calls over Wi-Fi even though Wi-Fi calling is on, Wi-Fi is connected, and VoLTE works.

> **Read first.** This writes a setting inside the phone's modem. It is proven on **one** phone, comes with no warranty, and should only be used on a line **you own**. It makes the modem believe Verizon's Wi-Fi-calling activation (including the emergency-address step) is done **without registering an emergency address** — see [Emergency calls](#emergency-calls-e911--please-read). Do not run it on a phone whose cellular service you cannot afford to lose.

> **Status:** proven on exactly one phone — a CAT S22 Flip (Android 11, T-Mobile device-group build) with a Verizon SIM and the Verizon carrier config active. It may apply to similar Qualcomm phones running a non-Verizon ROM on a Verizon SIM; that is **untested**. Reports welcome.

## The problem in one paragraph

Verizon's Wi-Fi-calling voice only registers if the modem's IMS settings file contains the SIM's own line number. Verizon-certified phones fill that in at setup; this phone's firmware has nothing that does, so the field is empty, the modem advertises `cs` instead of `cs,volte`, and Android reports no voice capability. This tool writes the line number into that one 20-byte field.

## Quick start

You need: a Mac or Linux computer, `python3` (3.8+), [libusb](https://libusb.info) (`brew install libusb` / `sudo apt install libusb-1.0-0`), a USB data cable, and the SIM's phone number.

**1. Open the phone's USB diag port.** On the phone's dialer, dial **`##3424#`** (DIAG). Keep the phone connected to the computer. (The tool cannot do this for you, and the code is device/firmware-specific.)

**2. Run the tool** (run it from a folder you don't mind it saving a backup file into):

```sh
curl -fsSL https://raw.githubusercontent.com/clippycoder/cat-s22-verizon-wfc-fix/main/fix.sh | bash
```

The one-liner downloads `fix.sh` from this repo and runs it, so it trusts GitHub and (for the one dependency, `pyusb`) PyPI.

A menu appears; everything is done from it:

```
  1) Check the current setting (read-only)
  2) Enable Wi-Fi calling voice (guided: sets the line number)
  3) Restore a saved backup
  4) Troubleshooting: list USB devices
  5) Quit
```

- **1** reads the setting and tells you whether it is empty.
- **2** walks you through the fix: it shows what it found, asks for the line number at a **hidden** prompt, asks you to confirm, saves a backup of the original, rewrites the item with only that field changed, reads it back and verifies.
- **3** lists the backups saved in the current folder (or lets you type a path) and writes the one you pick back.
- **4** lists the USB devices the computer can see and which one is a diag port.
- If more than one phone is connected in diag mode, it asks which one you mean.

**3. Reboot the phone** after step 2, turn Wi-Fi calling on in Android settings if it is not already, and try a call over Wi-Fi.

## Safety

- It changes **one setting**: it rewrites one 1024-byte file in the modem's storage with only 11 bytes different (bytes `0x0e`–`0x18`; the rest of the 20-byte field is zeroed). It never touches boot, the modem image, or partitions, and needs no root.
- The number you type is not passed as an argument and is not saved; only its last 4 digits are shown on the confirm line. The **backup file contains the previous value of the setting** (a phone number if one was set): don't share or commit it.
- If something is interrupted after the write started, the tool says the write *may* have happened — choose 1 to check, and 3 to restore the backup if needed.
- It checks that the item looks like the expected layout, not that the phone is a CAT S22 Flip: it will write to any diag-open phone whose item looks right, so connect only the phone you mean (the tool shows the USB id and asks if several are connected).
- Provided as-is, with no warranty. Writing to a modem's storage can in theory break things; you have a backup and menu option 3.

## After a SIM or number change

The stored number must equal the SIM's own number. If you change SIM or number, run the tool again (option 2). Verizon's own phone software does this automatically; this phone has nothing that does.

## Emergency calls (E911) — please read

The setting you are writing is, on Verizon phones, the marker that "Wi-Fi calling has been activated for this line", normally set **after the Wi-Fi-calling emergency-address setup completes**. This tool tells the modem it is activated **without registering an emergency address with Verizon**, and nothing on this phone can register one.

- With cellular coverage, 911 should still go over Verizon's normal LTE path (unaffected by this tool — inferred, not tested).
- Wi-Fi-only 911 behaviour on this phone is **unknown** and must never be tested with a live emergency call.
- On Verizon-certified phones the setting is written by the phone's own emergency-address setup, which registers the address at Verizon (inferred: per line, not per handset). This phone has no such setup, so it cannot create that registration.
- Keep an active SIM and cellular coverage, tell the dispatcher your location out loud, and register a Wi-Fi-calling emergency address with Verizon through a normal channel (e.g. the settings of a Verizon-certified phone on the same line, or Verizon support).

## Troubleshooting

- **"No phone with an open USB diag port found"** — the diag port is not open (dial `##3424#` again and keep the phone connected), the cable is charge-only, or the phone re-enumerated; use menu option 4 to see what the computer can see.
- **"libusb was not found"** — install it (see Quick start), then run the tool again.
- **Linux: "Could not open the diag port" / permission denied** — add a udev rule for the phone's `05c6` device (preferred), or run as root (`… | sudo bash`, which also runs pip and creates backups as root). On Linux the tool detaches the kernel's serial driver from the diag interface (e.g. `ttyUSB`); it comes back when you re-plug or reboot the phone.
- **macOS:** no driver is bound to the diag interface, so no extra drivers are needed. **Windows is not supported.**
- **"No reply from the modem"** — wait for the phone to finish booting and try again.
- **"The modem refused…"** — nothing was changed; open an issue with the message. (If you see "may or may not have gone through", follow the note.)
- **"This tool is interactive"** — run it in a real terminal window (it reads the menu from the keyboard).

## How it works (short)

The tool speaks the Qualcomm diag protocol (HDLC-framed commands, EFS2 file operations) over the phone's USB diag interface using `pyusb`. It reads `/nv/item_files/ims/qp_ims_service_enablement_config` (1024 bytes), replaces bytes `0x0e`–`0x21` with the line number as ASCII digits plus a NUL, and writes the file back with the standard EFS2 put request, then re-reads it to verify.

## Prior art

Generic Qualcomm EFS-over-diag tooling exists and was a useful reference for the protocol: [EfsTools](https://github.com/JohnBel/EfsTools), [QCSuper](https://github.com/P1sec/QCSuper), [qcom-efs-browser](https://github.com/catxeon/qcom-efs-browser), [edl](https://github.com/bkerler/edl). None of them targets this setting, and none is a one-liner; no code was copied from them. GUI tools such as QPST's EFS Explorer or QXDM can edit the same file by hand (not tested here).

## License

GPL-3.0-or-later — see [LICENSE](LICENSE).
