import yaml
import requests
import subprocess
from jinja2 import Template
import urllib3
import random
import time
import socket

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ---------------- CONFIG -----------------
PROXMOX_URL = "https://192.168.1.81:8006/api2/json"
PROXMOX_NODE = "pve"
PROXMOX_USER = "root@pam"
PROXMOX_PASS = "YOUR_PASSWORD"
PROXMOX_SSH_PUB = open("$HOME/.ssh/id_rsa.pub").read()
TEMPLATE_ID = 9000   # ID del template cloud-init già pronto
ANSIBLE_PLAYBOOK = "site.yaml"
ANSIBLE_INVENTORY_TEMPLATE = "ansible_inventory.j2"
ANSIBLE_INVENTORY_OUTPUT = "inventory.ini"

# --------------- Funzioni ----------------

def load_blueprint(path="blueprint.yaml"):
    with open(path) as f:
        return yaml.safe_load(f)

def get_ticket():
    data = {"username": PROXMOX_USER, "password": PROXMOX_PASS}
    r = requests.post(f"{PROXMOX_URL}/access/ticket", data=data, verify=False)
    r.raise_for_status()
    result = r.json()["data"]
    return result["ticket"], result["CSRFPreventionToken"]




def create_vm_proxmox(vm, ticket, csrf):
    """
    Clona una VM dal template cloud-init e applica configurazioni in modo sicuro,
    gestendo lock e retry.
    """
    headers = {
        "Cookie": f"PVEAuthCookie={ticket}",
        "CSRFPreventionToken": csrf
    }

    # Genera VMID casuale tra 100 e 999
    vmid = random.randint(100, 999)

    # Step 1: Clone dal template
    clone_url = f"{PROXMOX_URL}/nodes/{PROXMOX_NODE}/qemu/{TEMPLATE_ID}/clone"
    clone_payload = {
        "newid": vmid,
        "name": vm["name"],
        "full": 1  # clone full, non linked
    }
    r = requests.post(clone_url, headers=headers, data=clone_payload, verify=False)
    r.raise_for_status()
    print(f"[INFO] VM {vm['name']} clonata da template con VMID {vmid}")

    # Step 2: Attendi che il lock della VM sparisca
    for i in range(60):  # fino a 2 minuti circa
        status_url = f"{PROXMOX_URL}/nodes/{PROXMOX_NODE}/qemu/{vmid}/status/current"
        r_status = requests.get(status_url, headers=headers, verify=False)
        r_status.raise_for_status()
        status = r_status.json()["data"]
        if "lock" not in status:
            break
        time.sleep(2)
    else:
        raise Exception(f"[ERROR] VM {vm['name']} ancora lockata dopo 2 minuti")

    # Step 3: Configura cloud-init con retry
    config_payload = {
        "memory": vm["memory"],
        "cores": vm["cpu"],
        "ciuser": "vagrant",
        #"sshkeys": PROXMOX_SSH_PUB,
        "ipconfig0": f"ip={vm['ip']}/24,gw=192.168.1.1"
    }

    max_attempts = 5
    for attempt in range(1, max_attempts + 1):
        try:
            r = requests.post(f"{PROXMOX_URL}/nodes/{PROXMOX_NODE}/qemu/{vmid}/config",
                              headers=headers, data=config_payload, verify=False)
            r.raise_for_status()
            print(f"[INFO] Configurata VM {vm['name']} con IP {vm['ip']}")
            break
        except requests.exceptions.RequestException as e:
            print(f"[WARNING] Tentativo {attempt} configurazione fallito: {e}")
            time.sleep(5)
    else:
        raise Exception(f"[ERROR] Configurazione VM {vm['name']} fallita dopo {max_attempts} tentativi")

    # Step 4: Avvio VM
    start_url = f"{PROXMOX_URL}/nodes/{PROXMOX_NODE}/qemu/{vmid}/status/start"
    for attempt in range(1, max_attempts + 1):
        try:
            r_start = requests.post(start_url, headers=headers, verify=False)
            r_start.raise_for_status()
            print(f"[INFO] VM {vm['name']} avviata")
            break
        except requests.exceptions.RequestException as e:
            print(f"[WARNING] Tentativo {attempt} start VM fallito: {e}")
            time.sleep(5)
    else:
        raise Exception(f"[ERROR] Avvio VM {vm['name']} fallito dopo {max_attempts} tentativi")

    return vmid

def wait_for_ssh(ip, port=22, retries=20, delay=15):
    for attempt in range(1, retries + 1):
        try:
            s = socket.create_connection((ip, port), timeout=5)
            s.close()
            print(f"[INFO] SSH pronto su {ip}")
            return True
        except Exception as e:
            print(f"[WARNING] Tentativo {attempt}: SSH non pronto su {ip}, riprovo tra {delay}s")
            time.sleep(delay)
    raise Exception(f"[ERROR] SSH non disponibile su {ip} dopo {retries*delay} secondi")

def generate_ansible_inventory(blueprint, template_path, output_path):
    with open(template_path) as f:
        template = Template(f.read())
    inventory = template.render(blueprint=blueprint)
    with open(output_path, "w") as f:
        f.write(inventory)
    print(f"[INFO] Inventory Ansible scritto in {output_path}")

def run_ansible_playbook():
    cmd = ["ansible-playbook", "-i", ANSIBLE_INVENTORY_OUTPUT, ANSIBLE_PLAYBOOK]
    subprocess.run(cmd, check=True)



def cleanup_vms(vmid_map, ticket, csrf):
    print("[INFO] Eliminazione VM (cleanup via API) disabilitata")
    '''
    print("[INFO] Eliminazione VM (cleanup via API)")
    headers = {"Cookie": f"PVEAuthCookie={ticket}", "CSRFPreventionToken": csrf}
    for name, vmid in vmid_map.items():
        try:
            stop_url = f"{PROXMOX_URL}/nodes/{PROXMOX_NODE}/qemu/{vmid}/status/stop"
            r = requests.post(stop_url, headers=headers, verify=False)
            print(f"[INFO] Stop VM {name}: {r.status_code}")
        except Exception as e:
            print(f"[WARNING] Fallito stop VM {name}: {e}")

    time.sleep(30)  # attesa prima di destroy

    for name, vmid in vmid_map.items():
        try:
            destroy_url = f"{PROXMOX_URL}/nodes/{PROXMOX_NODE}/qemu/{vmid}"
            r = requests.delete(destroy_url, headers=headers, verify=False)
            print(f"[INFO] Destroy VM {name}: {r.status_code}")
        except Exception as e:
            print(f"[WARNING] Fallito destroy VM {name}: {e}")
    '''

# --------------- Main -------------------

if __name__ == "__main__":
    blueprint = load_blueprint("blueprint.yaml")
    ticket, csrf = get_ticket()
    vmid_map = {}

    try:
        for vm in blueprint["Resources"]:
            vmid = create_vm_proxmox(vm, ticket, csrf)
            vmid_map[vm["name"]] = vmid
            wait_for_ssh(vm['ip'])  # aspetta SSH prima di procedere

        generate_ansible_inventory(blueprint, ANSIBLE_INVENTORY_TEMPLATE, ANSIBLE_INVENTORY_OUTPUT)
        run_ansible_playbook()

        print("Attendo 15 minuti prima di eliminare la VM...")
        time.sleep(15 * 60)

    finally:
        cleanup_vms(vmid_map, ticket, csrf)
