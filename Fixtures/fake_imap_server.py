#!/usr/bin/env python3
"""Serveur IMAP de test pour le moteur de MAiLS (local, sans TLS, bibliothèque standard seulement).

Ce n'est PAS un vrai serveur : il sert à mesurer le moteur sur 100 000 messages sans toucher aux
comptes réels. Il parle un sous-ensemble d'IMAP4rev1 avec les réponses au format de Dovecot :
CAPABILITY, LOGIN, LIST, SELECT/EXAMINE, STATUS, UID FETCH, UID SEARCH, UID STORE (drapeaux), NOOP,
IDLE, LOGOUT. Commandes d'administration (réservées aux essais) : XADD <n>, XFLAG <uid> <drapeaux>,
XRESET (change UIDVALIDITY), XEXPUNGE <uid>.

Les messages sont engendrés de façon déterministe (graine = dossier + UID) : accents, mots codés
RFC 2047 (B, Q, UTF-8, ISO-8859-1), en-têtes pliés, commentaires dans les adresses, Date absente ou
décalée, chaînes de References, parties multiples.
"""
import argparse
import asyncio
import random
import re
import sys
import time
from email.utils import format_datetime
from datetime import datetime, timedelta, timezone

NAMES = [
    ("Élodie Martin", "elodie.martin", "exemple.fr"), ("José Álvarez", "jose.alvarez", "ejemplo.es"),
    ("Chloé Dupont", "chloe.dupont", "exemple.fr"), ("Zoë Müller", "zoe.mueller", "beispiel.de"),
    ("Renée Léger", "renee.leger", "exemple.fr"), ("Søren Kierkegaard", "soren", "eksempel.dk"),
    ("Anna Rossi", "anna.rossi", "esempio.it"), ("Support Facture", "no-reply", "boutique.example"),
    ("Newsletter Hebdo", "news", "lettre.example"), ("Stéphan", "stephan", "exemple.fr"),
    ("Maria García", "maria.garcia", "ejemplo.es"), ("Équipe Sécurité", "securite", "service.example"),
]
WORDS = ("rapport budget facture réunion livraison mise-à-jour sécurité abonnement commande rendez-vous "
         "projet contrat devis paiement relance invitation photos vacances demande confirmation résumé "
         "calendrier présentation maquette version corrigée urgent merci annulation remboursement").split()
BASE = datetime(2024, 1, 1, tzinfo=timezone.utc)
ALL_FLAGS = r"\Answered \Flagged \Deleted \Seen \Draft"
LOG_PATH = None  # --log : une ligne par commande reçue (sans arguments : pas de mot de passe dans le journal)


def log_command(cmd, sub=""):
    if LOG_PATH:
        with open(LOG_PATH, "a") as fh:
            fh.write((cmd + (" " + sub if sub else "")).upper() + "\n")


def encode_word(text, rnd):
    """Encode un texte en mot codé RFC 2047, avec une variante choisie au hasard."""
    kind = rnd.choice(["B-utf8", "Q-utf8", "Q-latin1"])
    if kind == "B-utf8":
        import base64
        return "=?UTF-8?B?" + base64.b64encode(text.encode("utf-8")).decode() + "?="
    if kind == "Q-utf8":
        return "=?utf-8?Q?" + q_encode(text.encode("utf-8")) + "?="
    try:
        return "=?ISO-8859-1?Q?" + q_encode(text.encode("latin-1")) + "?="
    except UnicodeEncodeError:
        import base64
        return "=?UTF-8?B?" + base64.b64encode(text.encode("utf-8")).decode() + "?="


def q_encode(raw):
    out = []
    for b in raw:
        if b == 0x20:
            out.append("_")
        elif (0x30 <= b <= 0x39) or (0x41 <= b <= 0x5A) or (0x61 <= b <= 0x7A):
            out.append(chr(b))
        else:
            out.append("=%02X" % b)
    return "".join(out)


def fold(name, value):
    """Plie une ligne d'en-tête à ~76 caractères, comme les vrais MTA."""
    line, out = name + ": ", []
    for token in value.split(" "):
        if len(line) + len(token) + 1 > 76 and line.strip():
            out.append(line.rstrip())
            line = " "
        line += token + " "
    out.append(line.rstrip())
    return "\r\n".join(out)


def gen_message(folder, uid):
    rnd = random.Random(f"{folder}:{uid}")
    name, local, domain = rnd.choice(NAMES)
    n_words = rnd.randint(2, 9)
    subject = " ".join(rnd.choice(WORDS) for _ in range(n_words)).capitalize()
    if rnd.random() < 0.12:
        subject = "Re: " + subject
    if rnd.random() < 0.05:
        subject += " " + "très " * rnd.randint(8, 14) + "long"
    enc_subject = encode_word(subject, rnd) if (rnd.random() < 0.35 or not subject.isascii()) else subject
    if rnd.random() < 0.25:
        disp = encode_word(name, rnd) if not name.isascii() else name
    else:
        disp = '"' + name.replace('"', '') + '"' if name.isascii() else encode_word(name, rnd)
    sent = BASE + timedelta(minutes=uid)
    tz = timezone(timedelta(hours=rnd.choice([0, 1, 2, -5, 9])))
    headers = []
    headers.append(f"Return-Path: <{local}@{domain}>")
    headers.append(f"Received: from mx.{domain} by imap.test with ESMTP; {format_datetime(sent)}")
    headers.append(fold("From", f"{disp} <{local}@{domain}>"))
    if rnd.random() < 0.3:
        headers.append(fold("To", 'stephan@exemple.fr, "Équipe, Projet" <equipe@exemple.fr> (liste)'))
    else:
        headers.append("To: stephan@exemple.fr")
    if rnd.random() < 0.15:
        headers.append("Cc: archive@exemple.fr, other@exemple.fr")
    headers.append(fold("Subject", enc_subject))
    if rnd.random() > 0.01:  # 1 % sans Date
        headers.append("Date: " + format_datetime(sent.astimezone(tz)))
    headers.append(f"Message-ID: <{folder.lower()}.{uid}.{rnd.randint(10**6, 10**7)}@{domain}>")
    if uid > 5 and rnd.random() < 0.3:
        parent = uid - rnd.randint(1, 5)
        headers.append(f"In-Reply-To: <{folder.lower()}.{parent}.0@{domain}>")
        headers.append(fold("References", f"<{folder.lower()}.{max(1, parent - 1)}.0@{domain}> "
                                          f"<{folder.lower()}.{parent}.0@{domain}>"))
    if local in ("news", "no-reply"):
        headers.append(f"List-Unsubscribe: <https://{domain}/u/{uid}>, <mailto:stop@{domain}>")
        headers.append("List-Unsubscribe-Post: List-Unsubscribe=One-Click")
    headers.append("MIME-Version: 1.0")
    paragraphs = [" ".join(rnd.choice(WORDS) for _ in range(rnd.randint(8, 30))) + "." for _ in range(rnd.randint(1, 4))]
    text = "\r\n\r\n".join(paragraphs) + "\r\n"
    if rnd.random() < 0.3:
        boundary = f"=_b{uid}"
        headers.append(f'Content-Type: multipart/alternative; boundary="{boundary}"')
        body = (f"--{boundary}\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n{text}"
                f"--{boundary}\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<html><body><p>"
                f"{'</p><p>'.join(paragraphs)}</p><img src=\"https://t.{domain}/p.gif\" width=\"1\" height=\"1\"></body></html>\r\n"
                f"--{boundary}--\r\n")
    else:
        headers.append("Content-Type: text/plain; charset=utf-8")
        headers.append("Content-Transfer-Encoding: 8bit")
        body = text
    header_block = ("\r\n".join(headers) + "\r\n\r\n").encode("utf-8")
    return header_block, body.encode("utf-8")


class Folder:
    def __init__(self, name, count, attrs=""):
        self.name, self.count, self.attrs = name, count, attrs
        self.uidvalidity = 1700000000
        self.flags = {}            # uid -> set de drapeaux
        self.expunged = set()
        self.cache = {}

    @property
    def uidnext(self):
        return self.count + 1

    def uids(self):
        return [u for u in range(1, self.count + 1) if u not in self.expunged]

    def message(self, uid):
        m = self.cache.get(uid)
        if m is None:
            h, b = gen_message(self.name, uid)
            m = (h, b)
            if len(self.cache) < 2000:
                self.cache[uid] = m
        return m

    def flag_set(self, uid):
        if uid in self.flags:
            return self.flags[uid]
        # Par défaut : lu si UID pair, sauf les 50 derniers messages
        return {r"\Seen"} if (uid % 3 != 0 and uid < self.count - 50) else set()


def parse_set(spec, folder):
    uids = folder.uids()
    if not uids:
        return []
    top = uids[-1]
    wanted = set()
    for part in spec.split(","):
        if ":" in part:
            a, b = part.split(":")
            a = top if a == "*" else int(a)
            b = top if b == "*" else int(b)
            lo, hi = min(a, b), max(a, b)
            wanted.update(range(lo, hi + 1))
        else:
            wanted.add(top if part == "*" else int(part))
    return [u for u in uids if u in wanted]


def header_fields(block, wanted):
    """Filtre un bloc d'en-têtes (avec pliage) sur une liste de champs, insensible à la casse."""
    wanted = {w.strip('"').lower() for w in wanted}  # le client peut envoyer des chaînes entre guillemets
    out, keep = [], False
    for line in block.decode("utf-8").split("\r\n"):
        if not line:
            break
        if line[0] in " \t":
            if keep:
                out.append(line)
            continue
        keep = line.split(":", 1)[0].lower() in wanted
        if keep:
            out.append(line)
    return ("\r\n".join(out) + "\r\n\r\n").encode("utf-8") if out else b"\r\n"


def internal_date(uid):
    d = BASE + timedelta(minutes=uid)
    return d.strftime("%d-%b-%Y %H:%M:%S +0000")


class Server:
    def __init__(self, inbox_count, extra_folders=False):
        self.folders = {
            "INBOX": Folder("INBOX", inbox_count),
            "Sent": Folder("Sent", 120, r"\Sent"),
            "Drafts": Folder("Drafts", 3, r"\Drafts"),
            "Archive": Folder("Archive", 2500, r"\Archive"),
            "Trash": Folder("Trash", 40, r"\Trash"),
        }
        if extra_folders:
            # Dossiers hors des cinq principaux : un dossier perso, un nom accentué (UTF-7 modifié : « Été »), les indésirables.
            self.folders["Factures"] = Folder("Factures", 30)
            self.folders["&AMk-t&AOk-"] = Folder("&AMk-t&AOk-", 12)
            self.folders["Junk"] = Folder("Junk", 5, r"\Junk")
        self.idlers = set()

    def notify_exists(self, folder):
        for w, f in list(self.idlers):
            if f is folder:
                w.write(f"* {len(folder.uids())} EXISTS\r\n".encode())

    async def handle(self, reader, writer):
        writer.write(b"* OK [CAPABILITY IMAP4rev1 IDLE UIDPLUS ENABLE CHILDREN] Serveur de test MAiLS pret.\r\n")
        selected = None
        authed = False
        while True:
            line = await reader.readline()
            if not line:
                break
            text = line.decode("utf-8", "replace").rstrip("\r\n")
            if not text:
                continue
            tag, _, rest = text.partition(" ")
            cmd, _, args = rest.partition(" ")
            cmd = cmd.upper()
            out = writer.write
            log_command(cmd, args.partition(" ")[0] if cmd == "UID" else "")
            try:
                if cmd == "CAPABILITY":
                    out(b"* CAPABILITY IMAP4rev1 IDLE UIDPLUS ENABLE CHILDREN\r\n")
                    out(f"{tag} OK Capability completed.\r\n".encode())
                elif cmd == "LOGIN":
                    m = re.match(r'"?([^" ]+)"? "?([^" ]+)"?$', args)
                    if m and m.group(1) == "test" and m.group(2) == "test":
                        authed = True
                        out(f"{tag} OK [CAPABILITY IMAP4rev1 IDLE UIDPLUS ENABLE CHILDREN] Logged in\r\n".encode())
                    else:
                        out(f"{tag} NO [AUTHENTICATIONFAILED] Authentication failed.\r\n".encode())
                elif not authed and cmd not in ("LOGOUT", "NOOP"):
                    out(f"{tag} BAD Not authenticated\r\n".encode())
                elif cmd == "LIST":
                    for f in self.folders.values():
                        attrs = (r"\HasNoChildren " + f.attrs).strip()
                        out(f'* LIST ({attrs}) "/" "{f.name}"\r\n'.encode())
                    out(f"{tag} OK List completed.\r\n".encode())
                elif cmd in ("SELECT", "EXAMINE"):
                    name = args.strip().strip('"')
                    f = self.folders.get(name)
                    if not f:
                        out(f"{tag} NO [NONEXISTENT] Mailbox doesn't exist: {name}\r\n".encode())
                        continue
                    selected = f
                    out(f"* FLAGS ({ALL_FLAGS})\r\n".encode())
                    out(f"* OK [PERMANENTFLAGS ({ALL_FLAGS} \\*)] Flags permitted.\r\n".encode())
                    out(f"* {len(f.uids())} EXISTS\r\n* 0 RECENT\r\n".encode())
                    out(f"* OK [UIDVALIDITY {f.uidvalidity}] UIDs valid\r\n".encode())
                    out(f"* OK [UIDNEXT {f.uidnext}] Predicted next UID\r\n".encode())
                    mode = "READ-ONLY" if cmd == "EXAMINE" else "READ-WRITE"
                    out(f"{tag} OK [{mode}] {cmd.title()} completed\r\n".encode())
                elif cmd == "STATUS":
                    m = re.match(r'"?([^"]+?)"? \((.*)\)', args)
                    f = self.folders.get(m.group(1)) if m else None
                    if not f:
                        out(f"{tag} NO Mailbox doesn't exist\r\n".encode())
                        continue
                    items = []
                    for it in m.group(2).split():
                        v = {"MESSAGES": len(f.uids()), "UIDNEXT": f.uidnext, "UIDVALIDITY": f.uidvalidity,
                             "UNSEEN": sum(1 for u in f.uids() if r"\Seen" not in f.flag_set(u))}.get(it.upper(), 0)
                        items.append(f"{it.upper()} {v}")
                    out(f'* STATUS "{f.name}" ({" ".join(items)})\r\n'.encode())
                    out(f"{tag} OK Status completed.\r\n".encode())
                elif cmd == "UID":
                    sub, _, subargs = args.partition(" ")
                    sub = sub.upper()
                    if selected is None:
                        out(f"{tag} BAD No mailbox selected\r\n".encode())
                    elif sub == "FETCH":
                        await self.uid_fetch(tag, subargs, selected, writer)
                    elif sub == "SEARCH":
                        m = re.match(r"(?:ALL|UID (\S+))$", subargs.strip(), re.I)
                        uids = parse_set(m.group(1), selected) if m and m.group(1) else selected.uids()
                        out(("* SEARCH " + " ".join(map(str, uids)) + "\r\n").encode())
                        out(f"{tag} OK Search completed\r\n".encode())
                    elif sub == "STORE":
                        m = re.match(r"(\S+) ([+-]?)FLAGS(?:\.SILENT)? \((.*)\)$", subargs.strip(), re.I)
                        if not m:
                            out(f"{tag} BAD Bad STORE\r\n".encode())
                            continue
                        for u in parse_set(m.group(1), selected):
                            cur = set(selected.flag_set(u))
                            new = set(m.group(3).split())
                            cur = cur | new if m.group(2) == "+" else cur - new if m.group(2) == "-" else new
                            selected.flags[u] = cur
                        out(f"{tag} OK Store completed\r\n".encode())
                    else:
                        out(f"{tag} BAD Unsupported UID command\r\n".encode())
                elif cmd == "NOOP":
                    if selected:
                        out(f"* {len(selected.uids())} EXISTS\r\n".encode())
                    out(f"{tag} OK Noop completed\r\n".encode())
                elif cmd == "IDLE":
                    out(b"+ idling\r\n")
                    key = (writer, selected)
                    self.idlers.add(key)
                    await writer.drain()
                    while True:
                        l2 = await reader.readline()
                        if not l2 or l2.strip().upper() == b"DONE":
                            break
                    self.idlers.discard(key)
                    out(f"{tag} OK Idle completed\r\n".encode())
                elif cmd == "LOGOUT":
                    out(b"* BYE Au revoir\r\n")
                    out(f"{tag} OK Logout completed\r\n".encode())
                    await writer.drain()
                    break
                # --- administration (essais) ---
                elif cmd == "XADD":
                    f = selected or self.folders["INBOX"]
                    f.count += int(args)
                    self.notify_exists(f)
                    out(f"{tag} OK ajouté, UIDNEXT {f.uidnext}\r\n".encode())
                elif cmd == "XFLAG":
                    u, _, fl = args.partition(" ")
                    selected.flags[int(u)] = set(fl.split())
                    out(f"{tag} OK\r\n".encode())
                elif cmd == "XEXPUNGE":
                    selected.expunged.add(int(args))
                    out(f"{tag} OK\r\n".encode())
                elif cmd == "XRESET":
                    selected.uidvalidity += 1
                    out(f"{tag} OK UIDVALIDITY {selected.uidvalidity}\r\n".encode())
                else:
                    out(f"{tag} BAD Commande inconnue\r\n".encode())
                await writer.drain()
            except Exception as e:  # noqa: BLE001
                out(f"{tag} BAD Erreur interne {e!r}\r\n".encode())
                await writer.drain()
        try:
            writer.close()
        except Exception:  # noqa: BLE001
            pass

    async def uid_fetch(self, tag, subargs, folder, writer):
        m = re.match(r"(\S+) \((.*)\)$", subargs.strip())
        if not m:
            writer.write(f"{tag} BAD Bad FETCH\r\n".encode())
            return
        uids = parse_set(m.group(1), folder)
        attrs = m.group(2)
        want_header = re.search(r"BODY(?:\.PEEK)?\[HEADER\.FIELDS \(([^)]*)\)\]", attrs, re.I)
        want_full = re.search(r"BODY(?:\.PEEK)?\[\]", attrs, re.I)
        want_flags = "FLAGS" in attrs.upper().replace("BODY", "")
        want_date = "INTERNALDATE" in attrs.upper()
        want_size = "RFC822.SIZE" in attrs.upper()
        for i, u in enumerate(uids):
            # Ne fabriquer le message que si la réponse l'exige (un FETCH de drapeaux seuls n'en a pas besoin).
            h, b = folder.message(u) if (want_header or want_full or want_size) else (b"", b"")
            parts = [f"UID {u}"]
            if want_flags:
                parts.append("FLAGS (" + " ".join(sorted(folder.flag_set(u))) + ")")
            if want_date:
                parts.append(f'INTERNALDATE "{internal_date(u)}"')
            if want_size:
                parts.append(f"RFC822.SIZE {len(h) + len(b)}")
            seq = folder.uids().index(u) + 1 if len(uids) < 50 else u  # numéro de séquence (sans expunge massif)
            head = f"* {seq} FETCH (" + " ".join(parts)
            payload = head.encode()
            if want_header:
                data = header_fields(h, want_header.group(1).split())
                payload += f" BODY[HEADER.FIELDS ({want_header.group(1)})] {{{len(data)}}}\r\n".encode() + data
            if want_full:
                data = h + b
                payload += f" BODY[] {{{len(data)}}}\r\n".encode() + data
            writer.write(payload + b")\r\n")
            if i % 500 == 499:
                await writer.drain()
        writer.write(f"{tag} OK Fetch completed (0.001 + 0.000 secs).\r\n".encode())


async def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=14300)
    ap.add_argument("--messages", type=int, default=100000)
    ap.add_argument("--log", default=None)
    ap.add_argument("--extra-folders", action="store_true", help="ajoute Factures, « Été » et Junk")
    args = ap.parse_args()
    global LOG_PATH
    LOG_PATH = args.log
    if LOG_PATH:
        open(LOG_PATH, "w").close()
    srv = Server(args.messages, args.extra_folders)
    server = await asyncio.start_server(srv.handle, "127.0.0.1", args.port, limit=1 << 20)
    print(f"prêt 127.0.0.1:{args.port} INBOX={args.messages}", flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
