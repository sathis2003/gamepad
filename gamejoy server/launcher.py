"""PocketPad Server window: one-time setup (firewall, ViGEmBus driver), then the gamepad server.

Built into PocketPadServer.exe by build_exe.ps1. Runs elevated (--uac-admin) because
netsh and msiexec need it. The server runs on a worker thread; the Tk window polls its state.
"""
import logging
import os
import queue
import subprocess
import sys
import threading
import time
import tkinter as tk

import servere

PORT = 8080
MAX_PLAYERS = 4
FIREWALL_RULE = "PocketPad {proto} {port}"
NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)

# Console palette, same values as lib/gamepad_screen.dart
BG, SURFACE, WELL, LINE = "#2A2E33", "#2B2F34", "#1B1E21", "#43494F"
INK, MUTED, OK, BAD = "#ECEEF0", "#A3AAB2", "#7BC96F", "#EE7D76"
FACE = ["#EBCB5E", "#6AA6EC", "#EE7D76", "#7BC96F"]
FONT = "Segoe UI"


def resource(rel: str) -> str:
    base = getattr(sys, "_MEIPASS", os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(base, rel)


def ensure_firewall() -> bool:
    ok = True
    for proto in ("TCP", "UDP"):
        name = FIREWALL_RULE.format(proto=proto, port=PORT)
        exists = subprocess.run(
            ["netsh", "advfirewall", "firewall", "show", "rule", f"name={name}"],
            capture_output=True, creationflags=NO_WINDOW,
        ).returncode == 0
        if not exists:
            added = subprocess.run(
                ["netsh", "advfirewall", "firewall", "add", "rule", f"name={name}",
                 "dir=in", "action=allow", f"protocol={proto}", f"localport={PORT}",
                 "profile=private", "remoteip=localsubnet"],
                capture_output=True, creationflags=NO_WINDOW,
            )
            ok = ok and added.returncode == 0
    return ok


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
    subprocess.run(["msiexec", "/i", msi, "/passive", "/norestart"])


class QueueLog(logging.Handler):
    def __init__(self, q):
        super().__init__()
        self.q = q

    def emit(self, record):
        # Tk 8.6 cannot draw characters outside the BMP (the server logs emoji)
        self.q.put("".join(c for c in self.format(record) if ord(c) < 0x10000))


class App:
    def __init__(self, root: tk.Tk):
        self.root = root
        self.server = None
        self.state = {"firewall": None, "driver": None, "server": "starting"}
        self.logs = queue.Queue()
        handler = QueueLog(self.logs)
        handler.setFormatter(logging.Formatter("%(asctime)s  %(message)s", "%H:%M:%S"))
        logging.getLogger().addHandler(handler)

        root.title("PocketPad Server")
        root.configure(bg=BG)
        root.resizable(False, False)
        try:
            root.iconbitmap(resource("icon.ico"))
        except tk.TclError:
            pass
        self._build()
        root.protocol("WM_DELETE_WINDOW", self.close)

        threading.Thread(target=self._run, daemon=True).start()
        self._poll()

    # ---------- layout ----------
    def _build(self):
        pad = {"padx": 24}
        head = tk.Frame(self.root, bg=BG)
        head.pack(fill="x", pady=(20, 16), **pad)
        dots = tk.Canvas(head, width=40, height=40, bg=BG, highlightthickness=0)
        for (x, y), c in zip([(20, 8), (8, 20), (32, 20), (20, 32)], FACE):
            dots.create_oval(x - 6, y - 6, x + 6, y + 6, fill=c, outline="")
        dots.pack(side="left")
        tk.Label(head, text="PocketPad Server", font=(FONT, 15, "bold"), bg=BG, fg=INK).pack(side="left", padx=12)

        tk.Label(self.root, text="Type this address in the phone app", font=(FONT, 10),
                 bg=BG, fg=MUTED).pack(anchor="w", **pad)
        row = tk.Frame(self.root, bg=BG)
        row.pack(fill="x", pady=(2, 0), **pad)
        self.ip = tk.Label(row, text="…", font=(FONT, 30, "bold"), bg=BG, fg=INK)
        self.ip.pack(side="left")
        self.copy_btn = self._button(row, "Copy", self.copy_ip)
        self.copy_btn.pack(side="left", padx=14)
        self.other_ips = tk.Label(self.root, text="", font=(FONT, 9), bg=BG, fg=MUTED, justify="left")
        self.other_ips.pack(anchor="w", **pad)

        tk.Label(self.root, text="Players", font=(FONT, 11, "bold"), bg=BG, fg=INK).pack(anchor="w", pady=(20, 6), **pad)
        box = tk.Frame(self.root, bg=WELL, highlightbackground=LINE, highlightthickness=1)
        box.pack(fill="x", **pad)
        self.slots = []
        for i in range(MAX_PLAYERS):
            r = tk.Frame(box, bg=WELL)
            r.pack(fill="x", padx=12, pady=5)
            dot = tk.Canvas(r, width=12, height=12, bg=WELL, highlightthickness=0)
            dot.pack(side="left")
            tk.Label(r, text=f"P{i + 1}", font=(FONT, 10, "bold"), bg=WELL, fg=INK, width=3).pack(side="left", padx=(6, 0))
            text = tk.Label(r, text="", font=(FONT, 10), bg=WELL, fg=MUTED, anchor="w")
            text.pack(side="left", fill="x", expand=True)
            self.slots.append((dot, text))

        self.status = {}
        st = tk.Frame(self.root, bg=BG)
        st.pack(fill="x", pady=(18, 0), **pad)
        for key in ("driver", "firewall", "server"):
            lbl = tk.Label(st, text="", font=(FONT, 10), bg=BG, fg=MUTED, anchor="w", justify="left", wraplength=380)
            lbl.pack(fill="x", pady=1)
            self.status[key] = lbl

        self.log_btn = self._button(self.root, "Show log", self.toggle_log)
        self.log_btn.pack(anchor="w", pady=(16, 20), **pad)
        self.log = tk.Text(self.root, height=12, width=60, bg=WELL, fg=MUTED, font=("Consolas", 9),
                           relief="flat", highlightthickness=1, highlightbackground=LINE, state="disabled")

    def _button(self, parent, text, cmd):
        return tk.Button(parent, text=text, command=cmd, font=(FONT, 10), bg=SURFACE, fg=INK,
                         activebackground=LINE, activeforeground=INK, relief="flat", bd=0,
                         padx=14, pady=5, cursor="hand2", highlightthickness=1, highlightbackground=LINE)

    # ---------- actions ----------
    def copy_ip(self):
        self.root.clipboard_clear()
        self.root.clipboard_append(self.ip.cget("text"))
        self.copy_btn.config(text="Copied")
        self.root.after(1500, lambda: self.copy_btn.config(text="Copy"))

    def toggle_log(self):
        if self.log.winfo_ismapped():
            self.log.pack_forget()
            self.log_btn.config(text="Show log")
        else:
            self.log.pack(fill="both", padx=24, pady=(0, 20))
            self.log_btn.config(text="Hide log")

    def close(self):
        if self.server:
            self.server.shutdown()  # releases every virtual controller
        self.root.destroy()

    # ---------- worker thread ----------
    def _run(self):
        self.state["firewall"] = ensure_firewall()
        if not driver_ready():
            self.state["driver"] = "installing"
            install_driver()
        self.state["driver"] = driver_ready()
        if not self.state["driver"]:
            self.state["server"] = "needs_restart"
            return
        self.server = servere.CricketGamepadServer(host="0.0.0.0", port=PORT, max_players=MAX_PLAYERS)
        self.ips = self.server._get_cricket_network_info()
        self.server.start_server()  # blocks until shutdown
        self.state["server"] = "stopped"

    # ---------- UI refresh ----------
    def _poll(self):
        s = self.state
        running = self.server is not None and self.server.running
        if running:
            s["server"] = "running"

        ips = getattr(self, "ips", None)
        if ips and self.ip.cget("text") == "…":
            self.ip.config(text=ips[0])
            if len(ips) > 1:
                self.other_ips.config(text="Other networks on this PC: " + ",  ".join(ips[1:]))

        clients = {}
        if self.server:
            with self.server.client_lock:
                clients = {cid: (c["address"][0], c["connected_at"]) for cid, c in self.server.clients.items()}
        for i, (dot, text) in enumerate(self.slots, start=1):
            dot.delete("all")
            if i in clients:
                ip, since = clients[i]
                mins = int((time.time() - since) // 60)
                dot.create_oval(1, 1, 11, 11, fill=OK, outline="")
                text.config(text=f"{ip}  ·  connected {mins} min", fg=INK)
            else:
                dot.create_oval(1, 1, 11, 11, fill="", outline=LINE, width=2)
                text.config(text="Waiting for a phone", fg=MUTED)

        drv = s["driver"]
        self._status("driver", *(
            ("Installing the controller driver…", MUTED) if drv == "installing" else
            ("✓  Controller driver ready", OK) if drv is True else
            ("✕  Controller driver not working. Close this window and open PocketPad Server again. "
             "If it still fails, restart the PC.", BAD) if drv is False else
            ("Checking the controller driver…", MUTED)))
        fw = s["firewall"]
        self._status("firewall", *(
            (f"✓  Firewall open on port {PORT} (private networks)", OK) if fw is True else
            (f"✕  Could not open port {PORT}. Phones may not connect. Run PocketPad Server as administrator.", BAD)
            if fw is False else ("Checking the firewall…", MUTED)))
        srv = s["server"]
        self._status("server", *(
            ("✓  Ready. Keep this window open while you play.", OK) if srv == "running" else
            (f"✕  Port {PORT} is in use. Close any other PocketPad Server and open this again.", BAD)
            if srv == "stopped" else ("", MUTED) if srv == "needs_restart" else ("Starting…", MUTED)))

        if not self.logs.empty():
            self.log.config(state="normal")
            while not self.logs.empty():
                self.log.insert("end", self.logs.get_nowait() + "\n")
            self.log.see("end")
            self.log.config(state="disabled")

        self.root.after(500, self._poll)

    def _status(self, key, text, color):
        self.status[key].config(text=text, fg=color)


def main():
    if sys.platform == "win32":
        import ctypes
        ctypes.windll.shcore.SetProcessDpiAwareness(1)  # sharp text on scaled displays
    root = tk.Tk()
    App(root)
    root.mainloop()


if __name__ == "__main__":
    main()
