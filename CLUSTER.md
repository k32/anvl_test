# Nested cluster boot flakiness

This document summarizes the investigation of the flakiness observed when
several `anvl_test` test cases bootstrap nested `familiar` clusters at the
same time (see `multi_site_cluster` in `test/test/att0.erl`), and the
mitigation applied in this repository.

> **Status update:** the library-level mitigation described in
> [What this repository does](#what-this-repository-does) is now
> implemented: the builds use a local clone of familiar at `./familiar`
> (branch `anvl-boot-flake-mitigation`) with a peer boot retry and the
> site RPC routed over the peer TCP control connection, and the test
> cases run in parallel again (the `serial_tests` workaround was
> removed). The standalone stress test below (6 concurrent clusters) can
> still exhaust the retries, but the parallel anvl test suite — the
> actual use case — passed many consecutive runs with 0 failures.

## Failure signature

A site of a nested cluster fails to boot with the following chain
(as seen in the preserved test case workdirs):

1. `familiar_site:do_start/2` calls `peer:start_link/1` for, e.g.,
   `site1@127.8.0.0`.
2. The spawned `erl` **exits with status 0 almost instantly** — it never
   registers a name with epmd (polling `epmd -names` during the hang shows
   the manager node registered, the site never appears).
3. `peer:start_it/2` has no channel to the detached child (no `connection`
   option was given), so it does not learn that the child died and waits out
   `?WAIT_BOOT_TIMEOUT` (15 s), then exits with `{timeout, ...}`.
4. The `familiar_site` gen_server crashes; the test case fails after
   burning 15–30 s.

The "instant exit 0" is the fingerprint that identified the code path.

## Mechanism

### How the child reports boot

`familiar` starts sites with the default `detached => true` and no
`connection` option, so `peer` falls back to the *distribution-based*
control channel. The child command line ends with:

```
-detached -peer_detached -user peer -origin <base64-of-pid>
```

where the pid is the peer gen_server (the "control process") living on the
manager node — for nested clusters, the test node.

### The child side

In `peer.erl` (stdlib 8.0), the `-user peer` boot does:

```erlang
{ok, [[Base64EncProc]]} ->
    OriginProcess = binary_to_term(base64:decode(Base64EncProc)),
    OriginLink = spawn(fun () ->
                               MRef = monitor(process, OriginProcess),
                               notify_when_started(dist, OriginProcess),
                               origin_link(MRef, OriginProcess)
                       end),
    ok = gen_server:call(OriginProcess, {starting, node()}),
```

and the link process is:

```erlang
origin_link(MRef, Origin) ->
    receive
        {'DOWN', MRef, process, Origin, _Reason} ->
            erlang:halt();          %% <<< status 0, immediately
        {init, started} ->
            notify_started(dist, Origin),
            origin_link(MRef, Origin)
    end.
```

`OriginProcess` is a **remote** pid, so `monitor/2` first requires a
distribution connection from the freshly-booted child to the manager node
(epmd lookup → TCP connect → handshake), and the
`gen_server:call({starting, ...})` rides that same connection.

### The race

Under concurrency, the site child hangs during startup (or dies silently,
which in the default distribution-based control mode matches the
`origin_link` `halt(0)` path above): while several clusters are booting at
once, each site child is simultaneously

- connecting *up* to its manager to deliver the boot notification, and
- being connected *to* by its manager (fixtures run `erpc` into the site
  right after boot),

plus the anvl daemon is connected to everything. The exact failing step
inside the child could not be pinned down: the child produces no output
(it is detached), passes through net_kernel setup (binds the dist
listener, talks to epmd) and then stalls; killing and retrying the boot
usually succeeds — until the retries are exhausted under heavy load.
Switching the boot handshake to a TCP control connection
(`peer => #{connection => 0}`) alone did *not* fix the concurrent boot
either, so the failure is deeper in the boot than the origin-monitor
channel — but it does remove the distribution from the manager↔site RPC
path (see below), which is why it was kept.

## Evidence

- Two standalone escripts, each with a *uniquely named* manager node and
  its own `/24` subnet, starting clusters simultaneously: one manager's
  three sites boot fine, the other's first site dies with exactly this
  signature. Winner/loser pattern, repeatable.
- The identical sequence run *sequentially* passes 100% (verified in-test
  with a copy of the code, and with `anvl --j-test 1`).
- Ruled out as causes: subnet/IP collisions (the subnet allocator hands
  out disjoint subnets), epmd name collisions (node names are unique per
  net), zombie nodes (epmd clean between runs), cookie mismatch, the
  `-pz`/name/`shutdown`/`peer_down` peer options (each tested
  individually inside a live test node), PATH/`~` quirks, and
  `ensure_epmd` killing epmd (epmd here is a stable `-daemon` process).

## Why anvl amplifies it

`anvl_test`'s `max_jobs` model default is 10 — test case instances are
*meant* to run in parallel, each on its own subnet. The design assumes
cluster bootstrapping is concurrency-safe; this peer-boot race breaks that
assumption, and multiple cluster-using test cases (or instances of one)
trip over it.

## Possible fixes, by layer

### OTP `peer` (root fix)

In `origin_link`, don't treat `noconnection` as fatal: only `halt()` on a
genuine process death, and retry the monitor/connect with backoff on
`noconnection`. A small change, and it matches the intent — the design of
per-cluster `/24` networks assumes boot connections are reliable.

### familiar (library-level mitigation — applied here)

The build uses a local clone of familiar at `./familiar` (gitignored,
branch `anvl-boot-flake-mitigation`) instead of the upstream `0.1.6` tag,
with three changes:

- `familiar_site:do_start` retries `peer:start_link` a few times with a
  1 s delay when the boot fails or times out (the last attempt
  propagates the error unchanged). Retrying inside `do_start` keeps the
  site state consistent, avoiding the `{error, {already_exists, Site}}`
  that a naive retry at the call site runs into.
- `default_peer_opts` sets `wait_boot => 5_000` so that several attempts
  fit into a typical test case timeout (the OTP default is 15 s).
- `default_peer_opts` sets `connection => 0`, and all manager→site RPC
  (`familiar_site:call`, previously `erpc`) goes over the peer TCP
  control connection via `peer:call` instead of the distribution. This
  removes the manager↔site distribution connections entirely: the only
  remaining distribution traffic is between the sites themselves.
  `peer:call` only supports MFA, so the fun-variant of the call applies
  the fun remotely with `erlang:apply/2` (note: `erlang:apply/1` is
  `undef` on this OTP).

With this mitigation the test cases run in parallel again
(`max_jobs` default of 10): the parallel suite passed many consecutive
runs with 0 failures, with the retries visibly kicking in and
recovering. A 6-way standalone cluster storm can still exhaust the
retries, so the mitigation is not complete — but it covers the real
use case. The following further options remain:

- Add jitter/stagger to site starts.
- Report the issue upstream: the failure is in the interaction of
  `peer` node boot with concurrent distribution activity, which
  familiar alone cannot fix.

### anvl_test (framework policy — previously applied, now removed)

`anvl_resource:set_max(anvl_test, 1)` (or `anvl --j-test 1`) serialized
the test cases and worked around the flake completely, at the cost of
parallelism. It was removed once the familiar-level retry made the
parallel suite reliable; reintroduce it if the flakiness resurfaces.

### Test case level (workaround, not recommended)

Stagger instances (`timer:sleep(N * ...)`) or retry-with-recovery in the
test body. Fragile: the stagger has no bound on someone else's boot
window, and retries must handle the `already_exists` cleanup.

## What this repository does

Both the root and the test projects use the local clone of familiar at
`./familiar` via `[deps, local]` instead of `[deps, git]`, carrying the
peer boot retry described above. The test cases run in parallel. If the
local clone is removed, the builds fall back to requiring a manual
restore: `git clone --branch 0.1.6 https://github.com/ieQu1/familiar.git
familiar` plus the patch (branch `anvl-boot-flake-mitigation`).
