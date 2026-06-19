# Interview Tips: Explaining Distributed Cache Systems

## The 10-Minute Explanation (What Interviewers Expect)

When asked "Design a distributed cache system," follow this structure:

### Minute 1: Clarify Scope
**What to say:**
```
"Before I design, I need to understand the constraints:
- How many requests per second? (helps size the cache)
- What's the read/write ratio? (determines consistency needs)
- How large is the dataset? (cache size vs. full data)
- Are we caching structured data or blobs?
- What's acceptable staleness? (eventual vs. strong consistency)
- Do we need persistence across crashes?"
```

**Why this matters:** Shows you're not just implementing, but understanding the problem.

---

### Minutes 2-3: High-Level Architecture
**Sketch this on the whiteboard (left to right):**

```
Clients (App Servers)
    ↓
Load Balancer (Consistent Hash)
    ↓
Cache Nodes (Primary + Replicas)
    ↓
Persistent Storage (Optional)
```

**What to say:**
```
"Here's the basic flow:
1. Clients don't directly access the cache
2. A load balancer routes requests using consistent hashing
   - This means adding nodes doesn't rehash all keys
3. Each cache node has replicas for availability
4. We persist to disk for durability (AOF or RDB)

This design gives us:
- Horizontal scalability (add more nodes)
- High availability (replicas handle failures)
- Balanced load (consistent hashing)
"
```

---

### Minutes 4-5: Deep Dive on Consistent Hashing

**Draw this:**
```
         Node A (keys 100-200)
              /\
             /  \
            /    \
        Node C    Node B
     (keys 0-100) (keys 200-300)
```

**What to say:**
```
"Consistent hashing solves a critical problem:

Naive approach: node = hash(key) % num_nodes
Problem: If we add one node, ~all keys rehash to different nodes
Result: Massive cache misses, database overload

Consistent hashing:
- Arrange nodes on a ring [0, 2^32)
- Each key hashes to a point on the ring
- Key goes to the nearest node clockwise
- Adding a node: only keys in that node's range migrate
- Benefit: O(k/n) rehashing, not O(k)

Implementation detail: Use ~150 virtual nodes per physical node
to ensure even distribution on the ring.
"
```

**Why interviewers ask about this:** It shows you understand **how** systems scale, not just "add more servers."

---

### Minutes 6-7: Replication & Consistency

**Draw this:**
```
Write: Client → Primary Cache → Replicas → AOF Log → Return

Read: Client → (Primary or Replica, depending on consistency need)
```

**What to say:**
```
"For each cache node, we maintain replicas (followers):

Replication happens asynchronously:
1. Primary receives write, updates memory immediately
2. Write goes to AOF log (append-only for durability)
3. Replicas pull updates (or primary pushes)
4. Return success to client

Why async? Synchronous replication would make writes slow.

For consistency:
- If we need eventual consistency: async replication is fine
  (good for sessions, recommendations, leaderboards)
- If we need strong consistency: wait for W out of N replicas to ack
  (needed for auth tokens, payment status)

If a primary dies:
- Health check fails after ~10 seconds
- Promote the replica with most recent data
- Elect a new replica from standby pool
- Brief outage, then automatic recovery
"
```

---

### Minute 8: Eviction & Memory Management

**What to say:**
```
"Memory is finite. When cache fills, we must evict something:

LRU (Least Recently Used):
- Evict the key accessed longest ago
- Works well for most workloads
- Pitfall: might evict a key that's accessed rarely but will be accessed soon

LFU (Least Frequently Used):
- Evict the key accessed least often overall
- Better for workloads where some keys are clearly hotter
- Pitfall: stale keys stay around if accessed once per day

TTL (Time To Live):
- Keys auto-expire after N seconds
- Great for session data and temporary data
- Pitfall: wastes memory if expired data not cleaned up

Monitor eviction rate:
- High eviction rate = cache too small
- Also indicates we're evicting hot keys, causing cache storms
"
```

---

### Minute 9: Failure Modes & Monitoring

**What to say:**
```
"At scale, failures are inevitable. Here's what can go wrong:

1. Cache node dies
   → Replicas take over (handled by cluster manager)
   → Requests that hashed to that node temporarily go to DB
   → Risk: thundering herd if too many requests hit DB

2. Network partition
   → Minority partition goes read-only (or offline)
   → Majority partition continues (quorum-based decisions)
   → Prevents split-brain (two primaries with conflicting data)

3. Thundering herd (cache stampede)
   → Hot key expires (e.g., user list for product)
   → 1000s of requests miss simultaneously
   → All query database, causing spike
   → Solution: use probabilistic early expiration, recompute in background

Monitoring:
- Hit rate (should be >80-90% for warm traffic)
- Eviction rate (high = undersized cache)
- P99 latency (indicates GC, network, or replication issues)
- Replication lag (should be <10-50ms)
- Memory usage (alert if >90%)
"
```

---

### Minute 10: Tradeoffs & Questions

**Close with this:**
```
"Key tradeoffs I've made:

1. Async replication for speed, but this means we can lose data
   if primary dies before replication finishes.
   Alternative: sync replication for durability, but slower writes.

2. LRU eviction for simplicity, but might evict hot keys.
   Alternative: LFU for accuracy, but more complex tracking.

3. Cluster-managed failover for automation, but 10-30s outage.
   Alternative: manual failover for control, but slower response.

What would change if you told me:
- Consistency is critical? (→ stronger replication guarantees)
- We have 100GB of data but only 10GB cache? (→ discuss tiering)
- Latency under 5ms is required? (→ local L1 cache + distributed L2)
"
```

---

## Common Follow-Up Questions & Answers

### Q1: "How do you handle data consistency between cache and database?"

**Good answer:**
```
"This depends on the use case:

Cache-Aside (most common):
- App checks cache first (→ hit)
- On miss, query database, update cache
- Simple but: app code is scattered with cache logic
- Problem: cache might be stale if data updated by another service

Write-Through:
- App writes to both database and cache together
- Slower but cache is always consistent with DB
- Problem: if cache write fails, rollback is complex

Write-Behind (risky):
- App writes only to cache, async flush to DB
- Fast but: can lose data if cache fails before flush
- Only use for non-critical data (views, scores)

Recommendation:
- Cache-Aside + TTL for most data
- Write-Through for critical data (auth, payments)
- Write-Behind only for metrics/analytics
"
```

### Q2: "How do you prevent cache stampede?"

**Good answer:**
```
"When a key expires with high traffic:

Naive approach:
- Key expires at time T
- All requests see miss, all query database
- Database gets 1000x spike

Better approach - Probabilistic expiration:
- Start evicting key at 90% of TTL
- Recompute in background before 100%
- Requests see hit, background job ensures freshness

Or - Locking approach:
- First request to miss acquires a lock
- Computes new value
- Other requests wait for lock, then see fresh value
- More complex but guaranteed single compute

Or - Longer TTL:
- Set TTL = compute_time + 2x
- By the time key expires, it's been recomputed

Monitor:
- If eviction rate > 10% of requests, cache is too small
"
```

### Q3: "What if we need to scale to 1 million requests/second?"

**Good answer:**
```
"Several layers:

Layer 1 - Client-side L1 cache:
- Every app server has local cache (in-memory)
- Reduces requests to distributed cache by 50%+

Layer 2 - Distributed cache (what we designed)
- Handles requests from app servers
- Scales horizontally

Layer 3 - Database caching:
- Database has its own cache (e.g., InnoDB buffer pool)
- Handles any requests that miss L2

CDN-style geography:
- If requests come from multiple regions
- Replicate cache across regions (eventual consistency)
- Reduce latency by serving locally

Load shedding (as last resort):
- If cache is overloaded, drop low-priority requests
- Better to serve fewer than overload the system
"
```

### Q4: "How do you monitor cache health?"

**Good answer:**
```
"Critical metrics:

Hit rate:
- Percentage of requests served from cache
- Should be >80% for warm traffic
- Dropping hit rate = cache too small or TTL too short

Eviction rate:
- Keys being evicted per second
- High eviction = undersized cache, thrashing
- Alert if eviction_rate > 10% of total requests

P50, P99 latency:
- Should be <5-10ms for memory access
- If P99 > 50ms, something's wrong (GC, replication, network)

Replication lag:
- How far behind are replicas?
- Should be <10-50ms
- Growing lag = replication traffic bottleneck

Memory usage:
- Alert if >90% of max
- Prevents unplanned evictions

Example dashboard:
- hit_rate gauge (>80%)
- eviction_rate counter
- latency_p99 gauge (<50ms)
- replication_lag gauge (<100ms)
- memory_used gauge (<90% max)

Set up alerts:
- hit_rate < 70%
- eviction_rate > 10% requests
- latency_p99 > 100ms
- replication_lag > 500ms
"
```

---

## What NOT to Do in an Interview

❌ **Don't start coding immediately**
- Spend first 5 minutes understanding the problem
- Whiteboard architecture first
- Code is a detail

❌ **Don't ignore consistency**
- Saying "eventual consistency" is good
- But not discussing the trade-off is bad
- Explain when you'd use strong vs. eventual

❌ **Don't skip failure modes**
- Caches **will** fail in production
- Showing you've thought about this is critical
- Mention health checks, failover, and monitoring

❌ **Don't be vague on replication**
- Saying "we replicate data" is not enough
- Explain: async vs. sync, what happens on primary death, quorum

❌ **Don't ignore eviction policy**
- Saying "we evict old stuff" is not enough
- Discuss LRU vs. LFU, thundering herd, monitoring

---

## Pacing: 10 Minutes to 1 Hour

**10-minute version:** Architecture → Consistent hashing → Replication → Eviction

**30-minute version:** Above + Consistency models + Failure scenarios + Monitoring

**1-hour version:** Everything above + Deep dive into any topic, code walkthrough, trade-off discussion

**If interviewer asks drill-down:** Be ready to:
- Code the consistent hash algorithm
- Explain quorum-based writes
- Discuss hot key handling
- Design cache invalidation strategy
- Analyze replication lag under load

---

## Key Phrases to Use

- "Trade-off: [fast/strong consistency/simple]"
- "At scale, [problem] happens; [solution] prevents it"
- "Monitor: [metric] tells us [health status]"
- "If requirements change to [X], we'd need to [change Y]"
- "This is similar to [real system]: Redis/Memcached/etc. handles it by [approach]"

---

## The Golden Rule

**Interview is about your thinking, not your answer.**

Interviewers care more about:
1. Do you think about trade-offs?
2. Do you know failure modes?
3. Can you explain your choices?
4. How do you measure success?

Than they care about:
- Exact architecture choices
- Perfect code
- Knowing every Redis flag

Focus on **communication and reasoning**, not perfection.
