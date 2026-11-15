#!/usr/bin/env python3
"""Remplit une Maildir (format Maildir++) avec les mêmes messages que fake_imap_server.py.
Usage : make_maildir.py <racine Maildir> [nb messages INBOX]   (par défaut 100000)
Les noms de fichiers croissent dans l'ordre alphabétique : Dovecot attribue donc les UID 1…N dans l'ordre.
La date interne IMAP = date de modification du fichier ; les drapeaux sont dans le suffixe « :2,… »."""
import importlib.util
import os
import sys

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("fake", os.path.join(here, "fake_imap_server.py"))
fake = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fake)

root = sys.argv[1]
count = int(sys.argv[2]) if len(sys.argv) > 2 else 100000
FOLDERS = {"INBOX": (count, ""), "Sent": (120, ".Sent"), "Drafts": (3, ".Drafts"), "Archive": (2500, ".Archive"), "Trash": (40, ".Trash")}

for name, (n, sub) in FOLDERS.items():
    base = os.path.join(root, sub) if sub else root
    for d in ("cur", "new", "tmp"):
        os.makedirs(os.path.join(base, d), exist_ok=True)
    for uid in range(1, n + 1):
        h, b = fake.gen_message(name, uid)
        data = h + b
        seen = uid % 3 != 0 and uid < n - 50
        fname = f"{1700000000 + uid:010d}.M{uid:08d}P1.test,S={len(data)}:2,{'S' if seen else ''}"
        path = os.path.join(base, "cur", fname)
        with open(path, "wb") as fh:
            fh.write(data)
        t = (fake.BASE + fake.timedelta(minutes=uid)).timestamp()
        os.utime(path, (t, t))
    print(f"{name}: {n} messages", flush=True)
