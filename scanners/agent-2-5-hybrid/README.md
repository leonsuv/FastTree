# Hybrid production scanner

This scanner combines Agent 5's `getattrlistbulk` traversal and worker scheduling with a compact retained tree. Each discovered file and directory has a node with parent ID, name, sizes, counts, type, and modification time. File IDs deduplicate hardlinks while retaining alias path nodes. Bottom-up aggregation runs after traversal.

`--index PATH` writes the complete versioned binary index atomically for `FastTreeCore`. The queue contains directory paths, so only active workers hold open directory descriptors. `--progress` emits periodic `FTPROGRESS` JSON lines on stderr. `--benchmark` omits the large JSON node list from output while retaining the full index in memory and reporting phase timings.

Build with `./build.sh`. Example:

```sh
./fasttree-scan /Users/me --threads 6 --index /tmp/scan.ftidx --benchmark --progress
```

The scanner stays on one filesystem, skips symbolic links and unsupported entries, and records permission skips. The index is local; no network code is used.
