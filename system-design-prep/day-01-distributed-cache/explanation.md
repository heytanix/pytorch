# Day 1: Distributed Cache System Design

## Deep Dive: Building a Redis-like Cache at Scale

When designing a caching system for a staff software engineer role, you need to understand not just how to build it, but **why each design choice matters** at scale. This isn't about memorizing Redis commands—it's about understanding the principles that make large-scale caching work reliably.

---

## 1. What is a Distributed Cache?

A distributed cache is a **shared data store** that:
- **Reduces latency** by keeping frequently accessed data in memory
- **Reduces load** on databases by serving hot data from cache
- **Improves throughput** by distributing the cache across multiple nodes
- **Provides durability** through replication and persistence

**When to use caching:**
- Read-heavy workloads (80/20 or 90/10 read/write ratios)
- Data that's accessed multiple times
- Data that's expensive to compute
- Session data, recommendations, leaderboards

**When NOT to use caching:**
- Data that must be strongly consistent (transactional accounts)
- Data that's written frequently and read infrequently
- Tiny datasets (latency savings < memory overhead)

---

## 2. Architecture: The Complete Picture

### Layer 1: Load Balancer with Consistent Hashing

**Problem:** If you hash requests naively, adding/removing cache nodes invalidates all keys.

**Solution:** Consistent hashing.

```
Traditional hashing:    node = hash(key) % num_nodes
                        ❌ If nodes change, almost all keys rehash

Consistent hashing:     key hashes to a point on a ring [0, 2^32)
                        ❌ Only keys near the changed node rehash
```

**How it works:**
- Each cache node occupies a range on the ring
- A key maps to the nearest node clockwise
- Adding node N: only keys in N's range migrate from its predecessor
- This limits **rehashing to O(k/n)** where k = total keys, n = number of nodes

**Implementation considerations:**
- Use **virtual nodes** (e.g., 150 per physical node) for better distribution
- Real-world: Memcached, Redis Cluster, Amazon ElastiCache all use it
- When you explain this, emphasize: "Only affected keys move, not all keys"

---

### Layer 2: Cache Nodes with Replication

Each primary node has **replicas (followers)** to handle:

1. **High availability:** If primary fails, promote a replica
2. **Read scaling:** Some systems let clients read from replicas (at lower consistency)
3. **Durability:** Data isn't lost if primary dies before persisting

**Write path:**
```
Client → Primary cache node → Write to memory
                           → Replicate to followers (async)
                           → AOF log (optional, for recovery)
                           → Return success to client
```

**Read path:**
```
Client → Primary cache node → Return from memory (fastest)
         [or replica, trade consistency for locality]
```

**Replication strategies:**

| Strategy | Consistency | Latency | Durability | Use Case |
|----------|-------------|---------|-----------|----------|
| **Async replication** | Eventual | Low | Medium | Session cache, recommendations |
| **Sync replication** | Strong | High | High | Critical data (auth tokens) |
| **Quorum** | Strong | Medium | High | Balanced systems |

**Trade-off:** Synchronous replication is safer but slower. Async is faster but you can lose data on failure.

---

### Layer 3: Eviction Policies (The Memory Boundary)

Memory is finite. When cache fills up, you must evict something. This is **non-negotiable** at scale.

**Common policies:**

| Policy | What's evicted | Pros | Cons | When to use |
|--------|--------------|------|------|------------|
| **LRU** (Least Recently Used) | oldest accessed | Intuitive | Can evict hot keys after 1 miss | General purpose |
| **LFU** (Least Frequently Used) | least often accessed | Evicts truly cold keys | Complex tracking | Social feeds |
| **TTL** (Time To Live) | expired keys | Natural cleanup | Wastes space if unused | Session data |
| **Random** | random key | Simple, fair | Unpredictable | Load shedding |

**The danger:** Evicting the wrong key can cause **cache storms**:
```
1. Hot key A is evicted (e.g., product listing)
2. Request comes in, cache misses
3. ALL requests hit database for that key
4. Database slows down, responses slow
5. More cache misses occur
6. Cascading failure
```

**Mitigation:**
- Use LFU to avoid evicting hot keys
- Set TTLs based on how "changeable" data is
- Monitor eviction rates (high rates = insufficient cache)
- Consider tiered caching (L1: tiny, hot; L2: large, warm)

---

## 3. Consistency Models: Picking Your Battles

Distributed caches have **three consistency levels**. You must choose based on application needs.

### Model 1: Eventual Consistency (Fastest)
```
Client 1 writes key="user_10" → Primary updates
Client 2 reads key="user_10" after 1ms → Replica hasn't replicated yet
                                        → Returns stale data
```
**Trade-off:** Low latency, eventual correctness
**Use when:** Page views, recommendations, leaderboards (small errors OK)

### Model 2: Strong Consistency (Slowest)
```
Client 1 writes key="user_10" → Primary waits for all replicas
                              → Then returns success
Client 2 reads key="user_10" → Gets latest value guaranteed
```
**Trade-off:** High latency, guaranteed correctness
**Use when:** Auth tokens, payment status, critical flags

### Model 3: Causal Consistency (The Middle Ground)
```
Client 1 writes A, then writes B (ordered operations)
Client 2 sees B, so it WILL see A (even on replica)
Client 3 might see neither (causally independent)
```
**Trade-off:** Medium latency, reasonable consistency
**Use when:** E-commerce (order must be seen before payment)

**Implementation note:** Achieve this with **vector clocks** or **version numbers** on keys.

---

## 4. Handling Failures: What Can Go Wrong

### Scenario 1: Cache Node Dies
```
Before: Primary A (keys 0-100), Replica A' (standby)
Failure: Primary A crashes
Detection: Health check times out (usually 3-10 seconds)
Action: Promote Replica A' to primary
        Elect a new replica from standby pool
Impact: 10-30s downtime, then automatic recovery
```

### Scenario 2: Network Partition
```
Before: 3 nodes: A, B, C
Partition: A can't reach B, C
           B, C can reach each other
Action: Minority (A) must go read-only (OR stop)
        Majority (B, C) continues as primary
Result: A's writes are lost, B and C stay consistent
```

**This is why Quorum-based systems exist:**
- Write succeeds only if W replicas acknowledge
- Read succeeds only if R replicas agree
- If W + R > total replicas, consistency is guaranteed
- Common: W=2, R=2 out of 3 (strong + fault-tolerant)

### Scenario 3: Thundering Herd (Cache Stampede)
```
Cache key expires at 12:00:00.000
1000 requests hit at 12:00:00.001
All miss, all query database simultaneously
Database gets 1000x traffic spike
Other queries suffer, timeout
More cache misses → cascading failure
```

**Solutions:**
1. **Probabilistic early expiration:** Evict 30% of keys before TTL ends, recompute in background
2. **Locking:** First miss acquires lock, computes, other threads wait
3. **Set TTL to longer than compute time:** TTL = compute_time + buffer

---

## 5. Key Algorithms & Patterns

### Consistent Hashing Algorithm

```python
# Simplified version
class ConsistentHash:
    def __init__(self, num_virtual_nodes=150):
        self.ring = {}  # hash -> node
        self.sorted_keys = []
        self.nodes = set()
        self.virtual_nodes = num_virtual_nodes
    
    def add_node(self, node):
        self.nodes.add(node)
        for i in range(self.virtual_nodes):
            virtual_key = f"{node}#{i}"
            hash_val = hash(virtual_key) % (2**32)
            self.ring[hash_val] = node
        self.sorted_keys = sorted(self.ring.keys())
    
    def get_node(self, key):
        hash_val = hash(key) % (2**32)
        # Find first node >= hash_val (clockwise)
        for node_hash in self.sorted_keys:
            if node_hash >= hash_val:
                return self.ring[node_hash]
        return self.ring[self.sorted_keys[0]]  # Wrap around
```

### Cache-Aside Pattern (Most Common)

```python
def get_user(user_id):
    # Check cache first
    cached = cache.get(f"user:{user_id}")
    if cached:
        return cached
    
    # Cache miss → fetch from DB
    user = db.query(f"SELECT * FROM users WHERE id = {user_id}")
    
    # Backfill cache for next time
    cache.set(f"user:{user_id}", user, ttl=3600)
    return user
```

**Pros:** Simple, clients control consistency
**Cons:** Cache-aside code everywhere, potential stale reads

### Write-Through Pattern (Less Common)

```python
def set_user(user_id, data):
    # Write to DB first
    db.update(f"users", data)
    
    # Then update cache
    cache.set(f"user:{user_id}", data)
    return True
```

**Pros:** Cache always consistent with DB
**Cons:** DB load not reduced for writes, double latency

### Write-Behind Pattern (Risky but Fast)

```python
def set_user(user_id, data):
    # Write to cache immediately
    cache.set(f"user:{user_id}", data)
    
    # Async flush to DB (background task)
    queue.enqueue("flush_to_db", user_id, data)
    return True  # Return before DB write!
```

**Pros:** Extremely fast writes (memory only)
**Cons:** Can lose data if cache dies before flushing, race conditions

---

## 6. Monitoring & Observability

What metrics tell you if your cache is healthy?

### Critical Metrics

| Metric | What it measures | Red flag | Example action |
|--------|-----------------|----------|-----------------|
| **Hit Rate** | % requests served from cache | <80% for warm traffic | Increase cache size or TTL |
| **Eviction Rate** | keys/sec being evicted | >10% of requests | Cache is too small |
| **P99 Latency** | 99th percentile response time | >50ms | Check for GC pauses or network |
| **Replication Lag** | milliseconds behind primary | >100ms | Too much replication traffic |
| **Memory Usage** | bytes used of max | >90% | Will cause thrashing evictions |

### Logging Strategy

```python
# Log cache misses on hot keys
if cache_miss and is_hot_key(key):
    log(f"cache_miss", key=key, db_latency=compute_time)

# Alert on eviction storms
if eviction_rate > threshold:
    alert("Cache eviction storm detected")

# Monitor replication lag
if replica_lag_ms > 100:
    log(f"replication_lag_exceeded", replica_id=r_id, lag=lag_ms)
```

---

## 7. Real-World Tradeoffs

| Consideration | Option A | Option B | Trade-off |
|---------------|----------|----------|-----------|
| **Size** | One big cache (100GB) | Many small caches (10GB each) | Availability vs. latency |
| **Replication** | Async | Sync | Speed vs. durability |
| **Eviction** | LRU | LFU | Simplicity vs. optimization |
| **Persistence** | AOF (write log) | RDB (snapshots) | Durability vs. memory efficiency |
| **Sharding** | Client-side (app decides) | Server-side (Redis Cluster) | Control vs. flexibility |

---

## 8. Common Interview Mistakes to Avoid

❌ **Mistake 1:** "We'll just make the cache bigger"
- **Why wrong:** Memory is expensive; you can't cache everything
- **Better answer:** Explain tiered caching, TTL strategy, eviction policies

❌ **Mistake 2:** "Consistency isn't important"
- **Why wrong:** Different data has different consistency needs
- **Better answer:** Discuss eventual vs. strong consistency trade-offs per use case

❌ **Mistake 3:** Ignoring failure modes
- **Why wrong:** Caches **will** fail; you need a plan
- **Better answer:** Describe health checks, failover, and thundering herd mitigation

❌ **Mistake 4:** Not discussing monitoring
- **Why wrong:** You can't fix what you can't see
- **Better answer:** Mention hit rate, eviction rate, replication lag, P99 latency

---

## Summary

A production-grade distributed cache requires:

1. **Consistent hashing** to minimize key movement
2. **Replication** for availability and reads scaling
3. **Eviction policies** to manage memory
4. **Consistency strategies** tailored to each data type
5. **Failure handling** (detection, promotion, quorum)
6. **Monitoring** (hit rate, eviction, latency)
7. **Operational patterns** (cache-aside, write-through, write-behind)

The key insight: **Caching is about tradeoffs, not perfection.** Every design choice costs something (latency, memory, consistency, or operational complexity). Your job is to pick the right tradeoff for the problem.
