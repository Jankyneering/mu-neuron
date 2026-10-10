import time
import os
import fcntl
import struct
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
RACK_UI_BUS = 1
RACK_UI_ADDR = 0x36
RACK_UI_REG_CONFIG = 0x03
RACK_UI_REG_ROTATION = 0x04
RACK_UI_REG_PUSH_COUNT = 0x06

I2C_SLAVE = 0x0703

# Halt confirmation window in seconds
halt_confirm_timeout = 10


class RackUI:
    """Register access to the Rack UI front panel controller.

    The panel exposes a rotary encoder and a push button as event counters.
    With config bits 0 and 1 set, both counters are cleared after being read,
    so each poll returns only the events that happened since the last poll.
    """

    def __init__(self, bus=RACK_UI_BUS, address=RACK_UI_ADDR):
        self.fd = os.open(f"/dev/i2c-{bus}", os.O_RDWR)
        fcntl.ioctl(self.fd, I2C_SLAVE, address)
        # Clear rotation and push counts after read
        self.write_reg(RACK_UI_REG_CONFIG, 0x03)

    def read_reg(self, reg):
        os.write(self.fd, bytes([reg]))
        return os.read(self.fd, 1)[0]

    def read_reg16(self, reg):
        os.write(self.fd, bytes([reg]))
        return struct.unpack(">h", os.read(self.fd, 2))[0]

    def write_reg(self, reg, value):
        os.write(self.fd, bytes([reg, value]))

    def poll(self):
        """Return (rotation_delta, new_presses) since the previous poll."""
        rotation = self.read_reg16(RACK_UI_REG_ROTATION)
        presses = self.read_reg(RACK_UI_REG_PUSH_COUNT)
        return rotation, presses

    def close(self):
        os.close(self.fd)


# Create display
serial = i2c(port=1, address=0x3C)  # Change address to 0x3D if needed
oled = ssd1306(serial, width=128, height=64)

width = oled.width
height = oled.height
font = ImageFont.load_default()

# Create queues for graphs
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

def draw_header(draw, title):
    draw.rectangle([(0, 0), (127, 15)], fill="white", outline=0)
    draw.text((64 - (6 * len(title)) // 2, 2), title, font=font, fill="black")

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
    draw.rectangle([(0, 0), (127, 63)], fill="black", outline="white")
    draw.text((4, 8), '!! HALT SYSTEM !!', font=font, fill="white")
    draw.text((4, 26), 'Press again to halt', font=font, fill="white")
    draw.text((4, 40), 'Rotate to cancel', font=font, fill="white")
    draw.text((4, 54), 'Timeout: ' + str(seconds_left) + 's', font=font, fill="white")

def halt_system():
    os.system("halt")

if __name__ == '__main__':
    init_graph_queues(zero=True)
    display_refresh_interval = 2.5
    queue_refresh_interval = display_refresh_interval
    display_sleep_time = 30
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

        while True:
            timeNow = time.time()

            # if not displaySleep and timeNow - displaySleepTimeLast >= display_sleep_time:
            #     oled.hide()
            #     displaySleep = True
            #     displaySleepTimeLast = timeNow

            if panel is not None:
                if timeNow - encoderPollLast >= encoder_poll_interval:
                    encoderPollLast = timeNow
                    rotation, presses = panel.poll()

                    if halt_confirm_until is not None:
                        if presses > 0:
                            halt_confirm_until = None
                            halt_system()
                        elif rotation != 0 or timeNow >= halt_confirm_until:
                            halt_confirm_until = None
                            displayTimeLast = 0.0
                    else:
                        if rotation != 0:
                            page = (page + rotation) % len(pages)
                            displayTimeLast = 0.0
                        if presses > 0:
                            if pages[page] is draw_halt_page:
                                halt_confirm_until = timeNow + halt_confirm_timeout
                                displayTimeLast = 0.0
                            else:
                                page = pages.index(draw_halt_page)
                                displayTimeLast = 0.0

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
