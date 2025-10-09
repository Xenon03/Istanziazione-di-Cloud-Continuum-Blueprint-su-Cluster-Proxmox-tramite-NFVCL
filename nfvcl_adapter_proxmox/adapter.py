import yaml
import requests
import subprocess
from jinja2 import Template
import urllib3
import random
import time
import socket
import os
import logging

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ---------------- CONFIG -----------------
PROXMOX_URL = "https://192.168.1.81:8006/api2/json"
PROXMOX_NODE = "pve"
PROXMOX_USER = "root@pam"
<<<<<<< HEAD
PROXMOX_PASS = open(os.path.expandvars("$HOME/.prox-cred/password")).read().strip()
PROXMOX_SSH_PUB = open(os.path.expandvars("$HOME/.ssh/id_rsa.pub")).read().strip()
=======
PROXMOX_PASS = "YOUR_PASSWORD"
PROXMOX_SSH_PUB = open("$HOME/.ssh/id_rsa.pub").read()
>>>>>>> 579f3e71a44e19fc0cd5ae0f9428b0abd749dc10
TEMPLATE_ID = 9000   # ID del template cloud-init già pronto
ANSIBLE_PLAYBOOK = "site.yaml"
ANSIBLE_INVENTORY_TEMPLATE = "ansible_inventory.j2"
ANSIBLE_INVENTORY_OUTPUT = "inventory.ini"

# Retry settings
SSH_RETRIES = 30      # tentativi per SSH
SSH_DELAY = 10        # secondi tra tentativi
LOCK_RETRIES = 60     # tentativi per lock VM
LOCK_DELAY = 2        # secondi tra tentativi

# Logging
logging.basicConfig(
    level=logging.INFO,
    format="[%(levelname)s] %(asctime)s - %(message)s",
    datefmt="%H:%M:%S"
)
log = logging.getLogger(__name__)


# --------------- Utility ----------------

def load_blueprint(path="blueprint.yaml"):
    with open(path) as f:
        return yaml.safe_load(f)


def wait_for_ssh(ip, port=22, retries=SSH_RETRIES, delay=SSH_DELAY):
    for attempt in range(1, retries + 1):
        try:
            s = socket.create_connection((ip, port), timeout=5)
            s.close()
            log.info(f"SSH pronto su {ip}")
            return True
        except Exception:
            log.warning(f"Tentativo {attempt}/{retries}: SSH non pronto su {ip}, riprovo tra {delay}s")
            time.sleep(delay)
    raise Exception(f"SSH non disponibile su {ip} dopo {retries*delay} secondi")


def generate_ansible_inventory(blueprint, template_path, output_path):
    with open(template_path) as f:
        template = Template(f.read())
    inventory = template.render(blueprint=blueprint)
    with open(output_path, "w") as f:
        f.write(inventory)
    log.info(f"Inventory Ansible scritto in {output_path}")


def run_ansible_playbook():
    cmd = ["ansible-playbook", "-i", ANSIBLE_INVENTORY_OUTPUT, ANSIBLE_PLAYBOOK]
    try:
        subprocess.run(cmd, check=True)
        log.info("Playbook Ansible completato con successo")
    except subprocess.CalledProcessError as e:
        log.error(f"Playbook fallito: {e}")
        raise


# --------------- Proxmox Client ----------------

class ProxmoxClient:
    def __init__(self, url, user, password, node):
        self.url = url
        self.user = user
        self.password = password
        self.node = node
        self.ticket, self.csrf = self.get_ticket()

    def _headers(self):
        return {"Cookie": f"PVEAuthCookie={self.ticket}", "CSRFPreventionToken": self.csrf}

    def get_ticket(self):
        data = {"username": self.user, "password": self.password}
        r = requests.post(f"{self.url}/access/ticket", data=data, verify=False)
        r.raise_for_status()
        result = r.json()["data"]
        return result["ticket"], result["CSRFPreventionToken"]

    def get_existing_vmids(self):
        url = f"{self.url}/cluster/resources?type=vm"
        r = requests.get(url, headers=self._headers(), verify=False)
        r.raise_for_status()
        vms = r.json()["data"]
        return {vm["vmid"] for vm in vms}

    def generate_free_vmid(self, min_id=100, max_id=999, max_attempts=50):
        existing = self.get_existing_vmids()
        for _ in range(max_attempts):
            vmid = random.randint(min_id, max_id)
            if vmid not in existing:
                return vmid
        raise Exception("Non trovato un VMID libero dopo diversi tentativi")

    def create_vm(self, vm):
        vmid = self.generate_free_vmid()

        # Step 1: Clone dal template
        clone_url = f"{self.url}/nodes/{self.node}/qemu/{TEMPLATE_ID}/clone"
        clone_payload = {
            "newid": vmid,
            "name": vm["name"],
            "full": 1
        }
        r = requests.post(clone_url, headers=self._headers(), data=clone_payload, verify=False)
        r.raise_for_status()
        log.info(f"VM {vm['name']} clonata da template con VMID {vmid}")

        # Step 2: Attendi che il lock sparisca
        for i in range(LOCK_RETRIES):
            status_url = f"{self.url}/nodes/{self.node}/qemu/{vmid}/status/current"
            r_status = requests.get(status_url, headers=self._headers(), verify=False)
            r_status.raise_for_status()
            status = r_status.json()["data"]
            if "lock" not in status:
                #log.info(f"Lock sparito per VM {vm['name']}")
                break
            #log.info(f"VM {vm['name']} in lock: {status.get('lock')}, attendo {LOCK_DELAY}s...")
            time.sleep(LOCK_DELAY)
        else:
            raise Exception(f"VM {vm['name']} ancora lockata dopo {LOCK_RETRIES*LOCK_DELAY} secondi")

        # Step 3: Configura memory e cores
        config_url = f"{self.url}/nodes/{self.node}/qemu/{vmid}/config"
        config_payload = {
            "memory": vm["memory"], 
            "cores": vm["cpu"],
            "ipconfig0": f"ip={vm['ip']}/24,gw=192.168.1.254"
        }
        r_cfg = requests.post(config_url, headers=self._headers(), data=config_payload, verify=False)
        r_cfg.raise_for_status()
        log.info(f"Configurata VM {vm['name']} con memory={vm['memory']} MB e cores={vm['cpu']}")

        # Step 4: Verifica presenza cloud-init
        r_cfg = requests.get(config_url, headers=self._headers(), verify=False)
        r_cfg.raise_for_status()
        cfg = r_cfg.json()["data"]
        ide2 = cfg.get("ide2", "")
        if "cloudinit" not in ide2:
            raise Exception(f"VM {vm['name']} clonata senza disco cloud-init valido!")
        log.info(f"Disco cloud-init presente: {ide2}")

        # Step 4.5: Resize disco root
        resize_url = f"{self.url}/nodes/{self.node}/qemu/{vmid}/resize"
        resize_payload = {
            "disk": "scsi0",   # o virtio0 se il template lo usa
            "size": "40G"
        }
        r_resize = requests.put(resize_url, headers=self._headers(), data=resize_payload, verify=False)
        r_resize.raise_for_status()
        log.info(f"Disco root ridimensionato a {resize_payload['size']} per VM {vm['name']}")

        # Step 5: Avvia VM
        start_url = f"{self.url}/nodes/{self.node}/qemu/{vmid}/status/start"
        for attempt in range(1, 6):
            try:
                r_start = requests.post(start_url, headers=self._headers(), verify=False)
                r_start.raise_for_status()
                log.info(f"VM {vm['name']} avviata")
                break
            except requests.exceptions.RequestException as e:
                log.warning(f"Tentativo {attempt} start VM fallito: {e}")
                time.sleep(5)
        else:
            raise Exception(f"Avvio VM {vm['name']} fallito dopo 5 tentativi")

        return vmid

    def cleanup_vms(self, vmid_map):
        log.info("Eliminazione VM (cleanup via API)")
        for name, vmid in vmid_map.items():
            try:
                stop_url = f"{self.url}/nodes/{self.node}/qemu/{vmid}/status/stop"
                requests.post(stop_url, headers=self._headers(), verify=False)
                log.info(f"Stop VM {name}")
            except Exception as e:
                log.warning(f"Fallito stop VM {name}: {e}")

        time.sleep(30)

        for name, vmid in vmid_map.items():
            try:
                destroy_url = f"{self.url}/nodes/{self.node}/qemu/{vmid}"
                requests.delete(destroy_url, headers=self._headers(), verify=False)
                log.info(f"Destroy VM {name}")
            except Exception as e:
                log.warning(f"Fallito destroy VM {name}: {e}")


# --------------- Main -------------------

if __name__ == "__main__":
    blueprint = load_blueprint("blueprint.yaml")
    client = ProxmoxClient(PROXMOX_URL, PROXMOX_USER, PROXMOX_PASS, PROXMOX_NODE)
    vmid_map = {}

    try:
        for vm in blueprint["Resources"]:
            vmid = client.create_vm(vm)
            vmid_map[vm["name"]] = vmid

            log.info(f"Attendo SSH sulla VM {vm['name']} ({vm['ip']})")
            wait_for_ssh(vm['ip'])

        generate_ansible_inventory(blueprint, ANSIBLE_INVENTORY_TEMPLATE, ANSIBLE_INVENTORY_OUTPUT)
        run_ansible_playbook()

        log.info("Attendo 15 minuti prima di eliminare le VM...")
        time.sleep(15 * 60)

    finally:
        client.cleanup_vms(vmid_map)
