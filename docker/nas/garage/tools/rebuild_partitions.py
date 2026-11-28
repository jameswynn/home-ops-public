"""Rebuild garage's `version` Merkle tree for specific partitions (garage must NOT be running).

Usage: python3 rebuild_partitions.py <db.sqlite> <partition> [<partition> ...]

For each partition p (= first byte of the item key, PARTITION_BITS=8):
  1. delete every node of tree_version_COLON_merkle_tree whose key starts with u16be(p)
  2. for every row of tree_version_COLON_table whose key starts with byte p,
     upsert merkle_todo[k] = blake2b512(v)[:32]  (same as garage's update_entry_with)
  3. for merkle_todo rows of p whose item no longer exists in the table, keep/force the
     empty value (= deletion) so the worker drops them from the rebuilt tree
Garage's Merkle worker then rebuilds the partition tree from an empty root.
"""
import hashlib
import sqlite3
import sys

TREE = "tree_version_COLON_merkle_tree"
TODO = "tree_version_COLON_merkle_todo"
TABLE = "tree_version_COLON_table"


def blake2sum(b: bytes) -> bytes:
    return hashlib.blake2b(b, digest_size=64).digest()[:32]


db_path, parts = sys.argv[1], [int(p) for p in sys.argv[2:]]
c = sqlite3.connect(db_path, isolation_level=None)
c.execute("PRAGMA busy_timeout=10000")
c.execute("BEGIN IMMEDIATE")
for p in parts:
    lo2, hi2 = p.to_bytes(2, "big"), (p + 1).to_bytes(2, "big")
    lo1, hi1 = bytes([p]), bytes([p + 1]) if p < 255 else None

    deleted = c.execute(f'DELETE FROM "{TREE}" WHERE k >= ? AND k < ?', (lo2, hi2)).rowcount

    rng = "k >= ? AND k < ?" if hi1 else "k >= ?"
    args = (lo1, hi1) if hi1 else (lo1,)
    queued = 0
    for k, v in c.execute(f'SELECT k, v FROM "{TABLE}" WHERE {rng}', args).fetchall():
        c.execute(f'INSERT OR REPLACE INTO "{TODO}" (k, v) VALUES (?, ?)', (k, blake2sum(v)))
        queued += 1
    # Pending todo entries for items that no longer exist must be deletions (empty value).
    qrng = "td.k >= ? AND td.k < ?" if hi1 else "td.k >= ?"
    stale = [k for (k,) in c.execute(
        'SELECT td.k FROM "%s" td WHERE %s AND td.v != X\'\' '
        'AND NOT EXISTS (SELECT 1 FROM "%s" t WHERE t.k = td.k)' % (TODO, qrng, TABLE), args).fetchall()]
    for k in stale:
        c.execute('UPDATE "%s" SET v = X\'\' WHERE k = ?' % TODO, (k,))
    gone = len(stale)
    print(f"partition {p}: deleted {deleted} merkle nodes, queued {queued} items, forced {gone} deletions",
          flush=True)
c.execute("COMMIT")
print("committed", flush=True)
