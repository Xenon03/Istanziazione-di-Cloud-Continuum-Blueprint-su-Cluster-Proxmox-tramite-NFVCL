#!/bin/bash
qm destroy 9000
qm create 9000 --name debian-cloud --memory 1024 --cores 1 --net0 virtio,bridge=vmbr0
qm importdisk 9000 debian-12-genericcloud-amd64.qcow2 local-lvm 
qm set 9000 --scsi0 local-lvm:vm-9000-disk-0 --scsihw virtio-scsi-pci 
qm set 9000 --ide2 local-lvm:cloudinit,size=8M 
qm set 9000 --boot c --bootdisk scsi0 
qm set 9000 --ipconfig0 ip=192.168.1.99/24,gw=192.168.1.1
qm set 9000 --ciuser vagrant  --sshkey "/share/id_rsa.pub"
qm template 9000 
