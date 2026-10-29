"""PocketPad Server: one-time setup (firewall, ViGEmBus driver), then the gamepad server.

Built into PocketPadServer.exe by build_exe.ps1. Runs elevated (--uac-admin) because
netsh and msiexec need it.
"""
import os
import subprocess
import sys

import servere

PORT = 8080
FIREWALL_RULE = "PocketPad {proto} {port}"


def resource(rel: str) -> str:
    base = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(base, rel)


def ensure_firewall():
    for proto in ("TCP", "UDP"):
        name = FIREWALL_RULE.format(proto=proto, port=PORT)
        exists = subprocess.run(
            ["netsh", "advfirewall", "firewall", "show", "rule", f"name={name}"],
            capture_output=True,
        ).returncode == 0
        if not exists:
            subprocess.run(
                ["netsh", "advfirewall", "firewall", "add", "rule", f"name={name}",
                 "dir=in", "action=allow", f"protocol={proto}", f"localport={PORT}",
                 "profile=private", "remoteip=localsubnet"],
                capture_output=True,
            )
            print(f"Firewall: allowed {proto} {PORT}")


def driver_ready() -> bool:
    if not servere.VGAMEPAD_AVAILABLE:
        return False
    try:
        servere.vg.VX360Gamepad()
        return True
    except Exception:
        return False


def install_driver():
    # bundled by --collect-all vgamepad in build_exe.ps1
    msi = resource(os.path.join("vgamepad", "win", "vigem", "install", "x64", "ViGEmBusSetup_x64.msi"))
    print("Installing the ViGEmBus controller driver (one time, ~10 seconds)...")
    subprocess.run(["msiexec", "/i", msi, "/passive", "/norestart"])


def main():
    if sys.platform == "win32":
        import ctypes
        ctypes.windll.kernel32.SetConsoleTitleW("PocketPad Server")
    print("PocketPad Server")
    print("=" * 40)
    ensure_firewall()
    if not driver_ready():
        install_driver()
        if not driver_ready():
            print("\nDriver installed. Close this window and open PocketPad Server again.")
            input("Press Enter to exit")
            return
    print("Keep this window open while you play.\n")
    servere.CricketGamepadServer(host="0.0.0.0", port=PORT, max_players=4).start_server()


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # keep the window open so the error is readable
        print(f"\nPocketPad Server stopped: {e}")
        input("Press Enter to exit")
