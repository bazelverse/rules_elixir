"""Deterministic partitioning of test files across parallel shards.

Sharding an ExUnit suite is not just a matter of splitting a list. Ecto's SQL sandbox
isolates concurrent tests inside one BEAM VM and does nothing across OS processes, so
parallel Bazel targets against one database deadlock; each shard needs its own. And the fixed
cost per shard -- sandbox setup, staging an ERL_LIBS tree, BEAM boot, app load -- is paid by
every shard and does not divide, which is what puts a floor under the useful shard count.

Both are the caller's to decide. What is general is the dealing.
"""

def shard_names(count):
    """Shard suffixes, e.g. ["s0", "s1", ...]. Used in target names and database names."""
    return ["s{}".format(i) for i in range(count)]

def partition_by_shard(srcs, count, heavy_srcs = []):
    """Split srcs into `count` disjoint, deterministic buckets.

    Two passes, both round-robin over a sorted list: the known-heavy files first so they land
    in different shards, then everything else.

    The heavy pass exists because balancing by file count assumes files cost roughly the same,
    and measured they do not -- two files sharing one bucket made that shard nearly twice the
    next slowest. `heavy_srcs` is a hint, not a contract: a stale entry costs a slightly worse
    balance, a missing one shows up as a single slow shard.

    Note that no shard count divides a single test, so the slowest shard cannot go below
    roughly (fixed cost + the slowest test) however high `count` goes.

    Args:
      srcs: the ExUnit test files to partition.
      count: number of shards.
      heavy_srcs: files to deal out first, spread across different shards.

    Returns:
      A dict of shard name -> list of srcs. Every shard is present even when empty, so a
      generated target list always matches whatever provisions the shards.
    """
    names = shard_names(count)
    buckets = {name: [] for name in names}

    heavy = [src for src in sorted(srcs) if src in heavy_srcs]
    rest = [src for src in sorted(srcs) if src not in heavy_srcs]

    for index, src in enumerate(heavy):
        buckets[names[index % count]].append(src)

    # Offset by len(heavy) so the light files keep filling round-robin from where the heavy
    # pass stopped, rather than piling the first few onto shards that already hold one.
    for index, src in enumerate(rest):
        buckets[names[(index + len(heavy)) % count]].append(src)

    return buckets
