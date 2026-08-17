load("//private:shards.bzl", _partition_by_shard = "partition_by_shard", _shard_names = "shard_names")

def shard_names(count):
    return _shard_names(count)

def partition_by_shard(srcs, count, heavy_srcs = []):
    return _partition_by_shard(srcs, count, heavy_srcs = heavy_srcs)
