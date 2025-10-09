#!/bin/bash

lvremove /dev/pve/data
lvcreate -L 100g -T pve/data --poolmetadatasize 1G
