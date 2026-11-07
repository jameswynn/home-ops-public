"""After the rebuild + a garage run: check the version Merkle tree for given partitions.

- every node in the partition decodes (structural check, no msgpack dependency)
- every Leaf's hash == blake2b512(table value)[:32] for items still in the table
- how many todo entries for these partitions are still pending
Usage: python3 verify_partitions.py <db.sqlite> <partition> [...]
"""
import hashlib
import sqlite3
import sys

TREE, TODO, TABLE = ("tree_version_COLON_merkle_tree", "tree_version_COLON_merkle_todo",
                     "tree_version_COLON_table")
c = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)


def b2(x):
    return hashlib.blake2b(x, digest_size=64).digest()[:32]


def parse_uint(v, p):
    b = v[p]
    if b < 0x80:
        return b, p + 1
    if b == 0xCC:
        return v[p + 1], p + 2
    raise ValueError("uint enc %#x at %d" % (b, p))


def parse_node(v):
    if v == b"\xa5Empty":
        return ("Empty",)
    if v.startswith(b"\x81\xacIntermediate"):
        p = 14
        if v[p] == 0xDC:
            n, p = int.from_bytes(v[p + 1:p + 3], "big"), p + 3
        elif v[p] & 0xF0 == 0x90:
            n, p = v[p] & 0x0F, p + 1
        else:
            raise ValueError("array hdr")
        prev = -1
        for _ in range(n):
            if v[p] != 0x92:
                raise ValueError("child hdr at %d" % p)
            ch, p = parse_uint(v, p + 1)
            if ch <= prev or v[p:p + 2] != b"\xc4\x20":
                raise ValueError("child body at %d" % p)
            prev, p = ch, p + 34
        if p != len(v):
            raise ValueError("trailing bytes")
        return ("Intermediate", n)
    if v.startswith(b"\x81\xa4Leaf\x92"):
        p = 7
        if v[p] == 0xDC:
            n, p = int.from_bytes(v[p + 1:p + 3], "big"), p + 3
        elif v[p] & 0xF0 == 0x90:
            n, p = v[p] & 0x0F, p + 1
        else:
            raise ValueError("key hdr")
        key = bytearray()
        for _ in range(n):
            x, p = parse_uint(v, p)
            key.append(x)
        if v[p:p + 2] != b"\xc4\x20" or p + 34 != len(v):
            raise ValueError("leaf hash")
        return ("Leaf", bytes(key), v[p + 2:p + 34])
    raise ValueError("unknown node %r" % v[:16])


for part in map(int, sys.argv[2:]):
    lo, hi = part.to_bytes(2, "big"), (part + 1).to_bytes(2, "big")
    nodes = c.execute('SELECT k, v FROM "%s" WHERE k >= ? AND k < ?' % TREE, (lo, hi)).fetchall()
    kinds, bad, leaf_ok, leaf_bad, leaf_gone = {}, 0, 0, 0, 0
    for k, v in nodes:
        try:
            n = parse_node(v)
        except ValueError:
            bad += 1
            continue
        kinds[n[0]] = kinds.get(n[0], 0) + 1
        if n[0] == "Leaf":
            row = c.execute('SELECT v FROM "%s" WHERE k = ?' % TABLE, (n[1],)).fetchone()
            if row is None:
                leaf_gone += 1
            elif b2(row[0]) == n[2]:
                leaf_ok += 1
            else:
                leaf_bad += 1
    root = c.execute('SELECT v FROM "%s" WHERE k = ?' % TREE, (lo,)).fetchone()
    tlo, thi = bytes([part]), bytes([part + 1]) if part < 255 else b"\xff" * 64
    pending = c.execute('SELECT count(*) FROM "%s" WHERE k >= ? AND k < ?' % TODO, (tlo, thi)).fetchone()[0]
    print("partition %d: nodes=%d %s undecodable=%d root=%s leaves hash_ok=%d hash_bad=%d not_in_table=%d todo_pending=%d"
          % (part, len(nodes), kinds, bad, parse_node(root[0])[0] if root else "absent",
             leaf_ok, leaf_bad, leaf_gone, pending))
