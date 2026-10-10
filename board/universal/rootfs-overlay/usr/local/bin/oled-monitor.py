import time
import os
import glob
import subprocess
import fcntl
import struct
import ctypes
import psutil
import queue
from socket import AddressFamily

from luma.core.interface.serial import i2c
from luma.oled.device import ssd1306
from luma.core.render import canvas
from PIL import ImageFont

max_temp_graph = 80
min_temp_graph = 15

# Rack UI front panel (I2C peripheral)
RACK_UI_ADDR = 0x36
RACK_UI_REG_VERSION = 0x00
RACK_UI_REG_CONFIG = 0x03
RACK_UI_REG_ROTATION = 0x04
RACK_UI_REG_PUSH_COUNT = 0x06
RACK_UI_REG_ANIMATION = 0x0E
RACK_UI_ANIM_IDLE = 0x00
RACK_UI_ANIM_BREATHING = 0x04
RACK_UI_ANIM_FOLLOWING = 0x80

I2C_SLAVE = 0x0703
I2C_RDWR = 0x0707
I2C_M_RD = 0x0001

# A single poll interval is short enough that these deltas can only come
# from a desynchronised register pointer, not a human hand: discard them.
max_plausible_rotation = 32
max_plausible_presses = 10

# Halt confirmation window in seconds
halt_confirm_timeout = 10

# Display blanks after this many seconds without encoder activity
display_sleep_time = 30

# Splash screen duration in seconds
splash_duration = 3


class I2cMsg(ctypes.Structure):
    _fields_ = [
        ("addr", ctypes.c_uint16),
        ("flags", ctypes.c_uint16),
        ("len", ctypes.c_uint16),
        ("buf", ctypes.POINTER(ctypes.c_uint8)),
    ]


class I2cRdwrIoctlData(ctypes.Structure):
    _fields_ = [("msgs", ctypes.POINTER(I2cMsg)), ("nmsgs", ctypes.c_uint32)]


def find_panel_bus(address=RACK_UI_ADDR):
    """Return the i2c adapter number where the panel answers, probing all
    /dev/i2c-* adapters (the i2c-gpio overlay number is dynamic)."""
    for bus in sorted(glob.glob("/dev/i2c-*")):
        try:
            number = int(bus.split("-")[-1])
            fd = os.open(bus, os.O_RDWR)
        except (OSError, ValueError):
            continue
        try:
            fcntl.ioctl(fd, I2C_SLAVE, address)
            os.write(fd, bytes([RACK_UI_REG_VERSION]))
            version = os.read(fd, 2)
            if len(version) == 2:
                return number
        except OSError:
            pass
        finally:
            os.close(fd)
    return None


class RackUI:
    """Register access to the Rack UI front panel controller.

    All reads use a single combined I2C transfer (register pointer write +
    repeated-start read, one STOP), so nothing on the bus can interleave
    between the pointer set and the read and desynchronise the pointer.

    The panel exposes a rotary encoder and a push button as event counters.
    With config bits 0 and 1 set, both counters are cleared after being
    read, so each poll returns only the events since the previous poll.
    If the panel firmware does not persist the config write, the counters
    accumulate and deltas are computed on the host instead.
    """

    def __init__(self, address=RACK_UI_ADDR):
        bus = find_panel_bus(address)
        if bus is None:
            raise OSError("Rack UI panel not found on any i2c bus")
        self.address = address
        self.animation_state = None
        self.fd = os.open(f"/dev/i2c-{bus}", os.O_RDWR)
        fcntl.ioctl(self.fd, I2C_SLAVE, address)
        # Firmware version sentinel, used to validate read alignment
        ver = self.read_regs(RACK_UI_REG_VERSION, 2)
        self.fw_version_major = ver[0]
        print(f"Rack UI: firmware version {ver[0]}.{ver[1] >> 4}.{ver[1] & 0x0F}", flush=True)

        # Ask for reset-on-read and verify with a few retries: a single
        # read-back right after the write can be corrupted by bus glitches
        self.reset_on_read = False
        for _ in range(5):
            self.write_reg(RACK_UI_REG_CONFIG, 0x03)
            try:
                config, _, _ = self.read_status()
            except OSError:
                continue
            if (config & 0x03) == 0x03:
                self.reset_on_read = True
                break
            time.sleep(0.05)
        if self.reset_on_read:
            # Discard any events that predate startup
            _, _, _ = self.read_status()
        else:
            print("Rack UI: reset-on-read not supported, using delta mode", flush=True)
            self.resync_baseline()

    def read_regs(self, reg, length):
        """Combined transfer: set the register pointer, then read `length`
        bytes in the same transaction (repeated start, single STOP)."""
        pointer = (ctypes.c_uint8 * 1)(reg)
        data = (ctypes.c_uint8 * length)()
        msgs = (I2cMsg * 2)(
            I2cMsg(self.address, 0, 1, pointer),
            I2cMsg(self.address, I2C_M_RD, length, data),
        )
        payload = I2cRdwrIoctlData(msgs, 2)
        fcntl.ioctl(self.fd, I2C_RDWR, payload)
        return bytes(data)

    def read_regs_checked(self, reg, length, retries=3):
        """Self-validating read: the transaction starts at register 0x00,
        whose first byte is the fixed firmware version sentinel. If the
        sentinel does not match, the transfer was misaligned (stale pointer
        on the panel); the read is retried and never trusted. Returns the
        `length` bytes starting at `reg`."""
        for attempt in range(retries):
            raw = self.read_regs(RACK_UI_REG_VERSION, reg + length)
            if raw[0] == self.fw_version_major:
                return raw[reg:reg + length]
            if attempt < retries - 1:
                time.sleep(0.01)
        print(f"Rack UI: misaligned read at 0x{reg:02X}, giving up this poll", flush=True)
        raise OSError("misaligned register read")

    def read_reg(self, reg):
        return self.read_regs_checked(reg, 1)[0]

    def write_regs_plain(self, reg, values):
        """Simple write through the plain i2c-dev file interface: the kernel
        builds the transfer itself, a completely different code path from
        I2C_RDWR."""
        os.write(self.fd, bytes([reg] + list(values)))

    def write_regs(self, reg, values):
        """Combined transfer: register pointer write + data bytes in a
        single transaction (repeated start, single STOP), mirroring the
        atomic read path so the pointer cannot desync mid-write."""
        # The buffer must stay referenced for the lifetime of the ioctl:
        # I2cMsg only holds a raw pointer, so a temporary would be freed
        # before the kernel copies the message.
        buf = (ctypes.c_uint8 * (1 + len(values)))(reg, *values)
        msgs = (I2cMsg * 1)(I2cMsg(self.address, 0, len(buf), buf))
        payload = I2cRdwrIoctlData(msgs, 1)
        fcntl.ioctl(self.fd, I2C_RDWR, payload)

    def write_reg(self, reg, value):
        self.write_regs(reg, [value])

    def set_animation(self, anim):
        if anim == self.animation_state:
            return
        # Write and verify: the animation register is the clearest signal
        # of a pointer desync, so a failed write is retried once
        for _ in range(3):
            self.write_reg(RACK_UI_REG_ANIMATION, anim)
            try:
                if self.read_reg(RACK_UI_REG_ANIMATION) == anim:
                    self.animation_state = anim
                    print(f"Rack UI: animation set to 0x{anim:02X}", flush=True)
                    return
            except OSError:
                continue
        print(f"Rack UI: animation write failed to stick (0x{anim:02X})", flush=True)
        self.animation_state = None

    def read_status(self):
        """Coherent snapshot of config, rotation count and push count in a
        single combined transfer (auto-increment from register 0x03)."""
        config, rot_hi, rot_lo, presses = self.read_regs_checked(RACK_UI_REG_CONFIG, 4)
        rotation = struct.unpack(">h", bytes([rot_hi, rot_lo]))[0]
        return config, rotation, presses

    def resync_baseline(self):
        """Re-read the counters to re-establish the delta-mode baseline."""
        _, self.last_rotation, self.last_presses = self.read_status()

    def poll(self):
        """Return (rotation_delta, new_presses) since the previous poll.

        Implausible deltas (pointer desynchronisation, bus glitches) are
        discarded and the baseline is resynchronised instead of acted on.
        """
        if self.reset_on_read:
            config, rotation, presses = self.read_status()
            if (config & 0x03) != 0x03:
                # Panel watchdog reset: re-arm and discard stale counters
                self.write_reg(RACK_UI_REG_CONFIG, 0x03)
                self.read_status()
                return 0, 0
            return rotation, presses

        try:
            _, rotation_abs, presses_abs = self.read_status()
        except OSError:
            return 0, 0
        rotation = rotation_abs - self.last_rotation
        rotation = rotation_abs - self.last_rotation
        rotation = struct.unpack(">h", struct.pack(">H", rotation & 0xFFFF))[0]
        presses = (presses_abs - self.last_presses) & 0xFF
        if abs(rotation) > max_plausible_rotation or presses > max_plausible_presses:
            print(f"encoder: implausible event dropped (rot {rotation}, presses {presses})", flush=True)
            self.resync_baseline()
            return 0, 0
        self.last_rotation = rotation_abs
        self.last_presses = presses_abs
        return rotation, presses

    def close(self):
        os.close(self.fd)


cpu_graph_queue = None
temp_graph_queue = None
ram_graph_queue = None

def make_graph_queues():
    global cpu_graph_queue, temp_graph_queue, ram_graph_queue
    cpu_graph_queue = queue.Queue(maxsize=width - 72)
    temp_graph_queue = queue.Queue(maxsize=width - 72)
    ram_graph_queue = queue.Queue(maxsize=width - 72)

def init_graph_queues(zero=False):
    if zero:
        while not cpu_graph_queue.full():
            cpu_graph_queue.put(0)
        while not temp_graph_queue.full():
            temp_graph_queue.put(min_temp_graph)
        while not ram_graph_queue.full():
            ram_graph_queue.put(0)

def get_IP():
    interfaces = psutil.net_if_addrs()
    try:        
        if 'wlan0' in interfaces and interfaces['wlan0'][0].family == AddressFamily.AF_INET:
            return interfaces['wlan0'][0].address
    except KeyError:
        pass
    try:
        if 'eth0' in interfaces and interfaces['eth0'][0].family == AddressFamily.AF_INET:
            return interfaces['eth0'][0].address
    except KeyError:
        pass
    return "No IPV4"

def get_CPU():
    return min(psutil.cpu_percent(), 100)

def get_Temp():
    return round(psutil.sensors_temperatures()['cpu_thermal'][0].current, 1)

def get_RAM():
    return psutil.virtual_memory().percent

def update_queues():
    for q, val in [
        (cpu_graph_queue, get_CPU()),
        (temp_graph_queue, get_Temp()),
        (ram_graph_queue, get_RAM()),
    ]:
        if q.full():
            q.get()
        q.put(val)

def get_os_version():
    try:
        with open("/etc/os-release") as f:
            for line in f:
                if line.startswith("PRETTY_NAME="):
                    return line.split("=", 1)[1].strip().strip('"')
    except OSError:
        pass
    return ""

def draw_header(draw, title):
    draw.rectangle([(0, 0), (127, 15)], fill="white", outline=0)
    draw.text((64 - (6 * len(title)) // 2, 2), title, font=font, fill="black")

def draw_splash(draw):
    draw.text((31, 20), 'uNeuron', font=font, fill="white")
    version = get_os_version()
    if version:
        draw.text((64 - (6 * len(version)) // 2, 34), version, font=font, fill="white")
    draw.text((13, 50), 'SDR base station OS', font=font, fill="white")

def draw_stats_page(draw):
    private_ip = get_IP()
    draw_header(draw, private_ip)

    # Legends
    draw.text((2, 18), 'CPU  :', font=font, fill="white")
    draw.text((2, 34), 'Temp :', font=font, fill="white")
    draw.text((2, 50), 'RAM  :', font=font, fill="white")

    # CPU
    draw.text((40, 18), str(cpu_graph_queue.queue[-1]) + '%', font=font, fill="white")
    draw.line([(72, 30), (127, 30)], fill="white", width=1)
    draw.line([(72, 18), (72, 30)], fill="white", width=1)
    for i, v in enumerate(cpu_graph_queue.queue):
        draw.point((72 + i, 30 - int((v / 100) * 12)), fill="white")

    # Temp
    draw.text((40, 34), str(temp_graph_queue.queue[-1]) + 'C', font=font, fill="white")
    draw.line([(72, 46), (127, 46)], fill="white", width=1)
    draw.line([(72, 34), (72, 46)], fill="white", width=1)
    for i, v in enumerate(temp_graph_queue.queue):
        draw.point((72 + i, 46 - int(((v - min_temp_graph) / (max_temp_graph - min_temp_graph)) * 12)), fill="white")

    # RAM
    draw.text((40, 50), str(ram_graph_queue.queue[-1]) + '%', font=font, fill="white")
    draw.line([(72, 62), (127, 62)], fill="white", width=1)
    draw.line([(72, 50), (72, 62)], fill="white", width=1)
    for i, v in enumerate(ram_graph_queue.queue):
        draw.point((72 + i, 62 - int((v / 100) * 12)), fill="white")

def draw_info_page(draw):
    draw_header(draw, "System Info")

    uptime = int(time.time() - psutil.boot_time())
    draw.text((2, 18), 'Up  : ' + f"{uptime // 3600}h{(uptime % 3600) // 60:02d}m", font=font, fill="white")

    load1, _, _ = psutil.getloadavg()
    draw.text((2, 30), 'Load: ' + f"{load1:.2f}", font=font, fill="white")

    disk = psutil.disk_usage('/')
    draw.text((2, 42), 'Disk: ' + f"{disk.used // (1024 * 1024)}M/{disk.total // (1024 * 1024)}M", font=font, fill="white")
    draw.rectangle([(0, 54), (127, 62)], outline="white")
    draw.rectangle([(1, 55), (1 + int(125 * disk.percent / 100), 61)], fill="white")

def draw_halt_page(draw):
    draw_header(draw, "System")
    draw.text((10, 26), 'Halt the system?', font=font, fill="white")
    draw.text((19, 44), 'Press to select', font=font, fill="white")

def draw_halt_confirm_page(draw, seconds_left):
    draw_header(draw, "!! HALT !!")
    draw.text((4, 22), 'Press again to halt', font=font, fill="white")
    draw.text((4, 36), 'Rotate to cancel', font=font, fill="white")
    draw.text((4, 50), 'Timeout: ' + str(seconds_left) + 's', font=font, fill="white")

def set_panel_animation(panel, anim):
    if panel is None:
        return
    try:
        panel.set_animation(anim)
    except OSError as e:
        print(f"Rack UI: animation write failed: {e}", flush=True)


def diagnose_writes(panel):
    """Controlled write experiments to locate where writes are lost.

    GP RAM (0x20) is plain scratch with no side effects; the rotation
    count (0x04) and config (0x03) have firmware write paths. Each write
    is verified by read-back, so the log shows exactly which registers
    accept host writes on this panel.
    """
    tests = [
        ("GP RAM 0x20", 0x20, 0xA5),
        ("GP RAM 0x21", 0x21, 0x5A),
        ("rotation count 0x04", RACK_UI_REG_ROTATION, 0x00),
        ("config 0x03", RACK_UI_REG_CONFIG, 0x03),
        ("animation 0x0E", RACK_UI_REG_ANIMATION, 0x04),
    ]
    for name, reg, value in tests:
        for method, writer in (("rdwr", panel.write_regs), ("plain", panel.write_regs_plain)):
            try:
                writer(reg, [value])
                time.sleep(0.05)
                back = panel.read_reg(reg)
                # A watchdog reset (IWDG, bit 3) reverts all registers to
                # defaults: report it so a failing write is distinguishable
                # from a write that was merely ignored
                cause = panel.read_reg(0x02)
                reset_note = "" if not cause & 0x08 else " [panel IWDG reset!]"
                print(f"diag: {name} [{method}]: wrote 0x{value:02X}, "
                      f"read back 0x{back:02X}, cause 0x{cause:02X} -> "
                      f"{'OK' if back == value else 'FAIL'}{reset_note}",
                      flush=True)
            except OSError as e:
                print(f"diag: {name} [{method}]: error {e}", flush=True)


def halt_system(panel):
    print("Halting system by user request", flush=True)
    oled.clear()
    oled.hide()
    if panel is not None:
        try:
            panel.set_animation(RACK_UI_ANIM_IDLE)
        except OSError:
            pass
    os.system("halt")

if __name__ == '__main__':
    import sys
    if '--diagnose-writes' in sys.argv:
        try:
            panel = RackUI()
        except OSError as e:
            print(f"Rack UI not found: {e}")
            raise SystemExit(1)
        diagnose_writes(panel)
        raise SystemExit(0)

    # Display setup only for the normal UI path: the diagnostic must run
    # without opening the OLED (and this late, after argument handling)
    PANEL_BUS = find_panel_bus() or 1
    serial = i2c(port=PANEL_BUS, address=0x3C)  # Change address to 0x3D if needed
    oled = ssd1306(serial, width=128, height=64)
    width = oled.width
    height = oled.height
    font = ImageFont.load_default()

    make_graph_queues()
    init_graph_queues(zero=True)
    display_refresh_interval = 2.5
    queue_refresh_interval = display_refresh_interval
    encoder_poll_interval = 0.1

    try:
        panel = RackUI()
    except OSError:
        panel = None
        print("Rack UI panel not found, running display-only")

    try:
        displaySleep = False
        displaySleepTimeLast = time.time()
        displayTimeLast = 0.0
        queueUpdateLast = time.time()
        encoderPollLast = time.time()

        page = 0
        pages = [draw_stats_page, draw_info_page, draw_halt_page]
        halt_confirm_until = None

        # Boot splash
        set_panel_animation(panel, RACK_UI_ANIM_FOLLOWING)
        with canvas(oled) as draw:
            draw_splash(draw)
        time.sleep(splash_duration)
        displaySleepTimeLast = time.time()

        while True:
            timeNow = time.time()

            if panel is not None:
                if timeNow - encoderPollLast >= encoder_poll_interval:
                    encoderPollLast = timeNow
                    rotation, presses = panel.poll()

                    if presses > 0:
                        print(f"encoder: {presses} press(es)", flush=True)
                    if halt_confirm_until is not None:
                        if presses > 0:
                            halt_confirm_until = None
                            halt_system(panel)
                        elif rotation != 0 or timeNow >= halt_confirm_until:
                            halt_confirm_until = None
                            displayTimeLast = 0.0
                    else:
                        if rotation != 0:
                            print(f"encoder: rotate {rotation}", flush=True)
                            page = (page + rotation) % len(pages)
                            displayTimeLast = 0.0
                        if presses > 0 and pages[page] is draw_halt_page:
                            halt_confirm_until = timeNow + halt_confirm_timeout
                            displayTimeLast = 0.0

                    if rotation != 0 or presses > 0:
                        if displaySleep:
                            displaySleep = False
                            oled.show()
                            set_panel_animation(panel, RACK_UI_ANIM_FOLLOWING)
                            displayTimeLast = 0.0
                        # Every interaction restarts the sleep countdown
                        displaySleepTimeLast = timeNow

            if not displaySleep and timeNow - displaySleepTimeLast >= display_sleep_time:
                displaySleep = True
                oled.hide()
                set_panel_animation(panel, RACK_UI_ANIM_BREATHING)

            if not displaySleep and timeNow - displayTimeLast >= display_refresh_interval:
                if halt_confirm_until is not None:
                    seconds_left = max(0, int(halt_confirm_until - timeNow) + 1)
                    with canvas(oled) as draw:
                        draw_halt_confirm_page(draw, seconds_left)
                    if seconds_left <= 0:
                        halt_confirm_until = None
                    displayTimeLast = timeNow - (display_refresh_interval - 0.5)
                else:
                    with canvas(oled) as draw:
                        pages[page](draw)
                    displayTimeLast = timeNow

            if timeNow - queueUpdateLast >= queue_refresh_interval:
                update_queues()
                queueUpdateLast = timeNow

            time.sleep(0.05)

    except KeyboardInterrupt:
        oled.hide()
        if panel is not None:
            panel.close()
        print("\n")
