import time
import psutil
import queue
from socket import AddressFamily

from luma.core.interface.serial import i2c
from luma.oled.device import ssd1306
from luma.core.render import canvas
from PIL import ImageFont

max_temp_graph = 80
min_temp_graph = 15

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

def drawDisplay():
    private_ip = get_IP()
    with canvas(oled) as draw:
        # IP bar
        draw.rectangle([(0, 0), (127, 15)], fill="white", outline=0)
        draw.text((64 - (6 * len(private_ip)) // 2, 2), private_ip, font=font, fill="black")

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

if __name__ == '__main__':
    init_graph_queues(zero=True)
    display_refresh_interval = 2.5
    queue_refresh_interval = display_refresh_interval
    display_sleep_time = 30
    try:
        displaySleep = False
        displaySleepTimeLast = time.time()
        displayTimeLast = time.time()
        queueUpdateLast = time.time()
        while True:
            timeNow = time.time()

            # if not displaySleep and timeNow - displaySleepTimeLast >= display_sleep_time:
            #     oled.hide()
            #     displaySleep = True
            #     displaySleepTimeLast = timeNow

            if not displaySleep and timeNow - displayTimeLast >= display_refresh_interval:
                drawDisplay()
                displayTimeLast = timeNow

            if timeNow - queueUpdateLast >= queue_refresh_interval:
                update_queues()
                queueUpdateLast = timeNow

            time.sleep(0.5)

    except KeyboardInterrupt:
        oled.hide()
        print("\n")
