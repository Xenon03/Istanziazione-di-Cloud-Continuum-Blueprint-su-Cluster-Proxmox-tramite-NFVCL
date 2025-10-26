# Istanziazione di Cloud Continuum Blueprint su Cluster Proxmox tramite NFVCL

Questo progetto implementa un **blueprint completo** per l'istanziazione automatizzata di un **cluster Proxmox** integrato nel framework **NFVCL (Network Function Virtualisation Continuous Lab)**.  
L'obiettivo è riprodurre e generalizzare il comportamento del **Vagrantfile originale del Cloud Continuum Blueprint**, estendendolo con funzionalità di orchestrazione e provisioning basate su **Infrastructure as Code (IaC)**.

---

## Obiettivi del progetto

- Automatizzare la creazione di un cluster *Proxmox* (controller + nodi worker) a partire da un **blueprint YAML**.
- Integrare l’ambiente con **NFVCL**, sfruttando il provider *Proxmox* già disponibile.
- Eseguire il **deployment dei servizi Cloud Continuum** (Keycloak, CouchDB, K3s, Crossplane, ecc.).
- Permettere l’esecuzione riproducibile di esperimenti (*Experiment-as-Code*).

---

## Architettura generale

Il blueprint definisce tre macchine virtuali:

| Nome              | Ruolo      | IP              | Servizi principali                   |
|-------------------|------------|-----------------|--------------------------------------|
| `fedcontr`        | Controller | `192.168.1.100` | Keycloak, CouchDB                    |
| `node2` (worker1) | Worker     | `192.168.1.101` | K3s, Crossplane, Experiment Provider |
| `node3` (worker2) | Worker     | `192.168.1.102` | K3s, Crossplane, Kubernetes Provider |

### Topologia

                            +-----------------------+
                            |      Controller       |
                            |      (fedcontr)       |
                            |     192.168.1.100     |
                            |   Keycloak / CouchDB  |
                            +-----------+-----------+
                                        |
                            Management Network (192.168.1.0/24)
                                        |
                +-----------------------+-----------------------+
                |                                               |
      +------------------+                             +------------------+
      |      Worker1     |                             |     Worker2      |
      |      node2       |                             |      node3       |
      |  192.168.1.101   |                             |   192.168.1.102  |
      | K3s / Crossplane |                             | K3s / Crossplane |
      +------------------+                             +------------------+

## Struttura della repository
```
├── blueprints/
│ └── experiment_exp1a.yaml # Blueprint principale del cluster
├── deployments/ # Manifest Kubernetes / Helm Charts
│ ├── experiment-provider/
│ ├── kubernetes-provider/
│ ├── couchDBsyncoperator/
│ └── compositeResources/
├── inventory.ini # Inventory Ansible generato
├── site.yaml # Playbook Ansible per la configurazione
├── README.md # Questo file
└── docs/ # Eventuali materiali di tesi o diagrammi
```


## Prerequisiti
- **NFVCL** correttamente installato e configurato  
- **Proxmox VE** con API accessibili (porta `8006`)  
- Accesso SSH via chiave pubblica (`~/.ssh/id_rsa.pub`)  