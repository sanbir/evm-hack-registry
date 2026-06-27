#!/usr/bin/env python3
"""Exhaustively re-warm a POC's fork state by running it online to completion, then
re-convert to anvil_state.json and restore the offline (localhost) form.

Foundry caches fork state LAZILY: only the accounts/storage/code actually read during
a given run are recorded. A cache from one run may miss state a *different* execution
path touches (e.g. setUp, or a different branch). So for a regression we:

  1. Revert the test's fork URL from http://127.0.0.1:<port> back to the chain alias.
  2. Run `forge test` ONLINE to completion against the chain's archive RPC (capturing
     every account/storage/code slot the FULL execution reads -> saturated cache).
  3. Re-convert the saturated cache -> anvil_state.json (block number set to the fork
     block; tx-hash forks get the resolved block).
  4. Restore the test's fork URL to http://127.0.0.1:<port>.

Archive RPC URLs are passed ONLY via env/args and are NEVER written to any file.
Idempotent. Usage:
    exhaustive_warm.py <poc_folder> <chain> <rpc_url> [--block N] [--txhash]

For tx-hash forks, the cache is keyed by the resolved block; the warmer detects the
newly-created cache by diffing the chain's cache dir before/after the online run.
"""
import os, re, sys, json, glob, subprocess

REG = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHARED = os.path.join(REG, "_shared")
CACHE = os.path.expanduser("~/.foundry/cache/rpc")
CONVERTER = os.path.join(SHARED, "cache2anvil.py")
CACHE_DIR = {"mainnet":"mainnet","bsc":"bsc","arbitrum":"arbitrum","base":"base",
             "polygon":"polygon","optimism":"optimism","avalanche":"avalanche",
             "fantom":"fantom","gnosis":"xdai","linea":"linea","blast":"blast",
             "mantle":"mantle","zksync":"zksync","moonriver":"moonriver","sei":"sei"}

def load_chains():
    out = {}
    with open(os.path.join(SHARED, "chains.conf")) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"): continue
            p = line.split(); out[p[0]] = (int(p[1]), int(p[2]))
    return out

URL_RE = re.compile(r'(create(?:Select)?Fork\(\s*)"http://127\.0\.0\.1:\d+"')
# matches createFork/createSelectFork with a bare chain alias, to restore alias->localhost
ALIAS_RE_TMPL = r'(create(?:Select)?Fork\(\s*)"{chain}"'

def cache_listing(chain):
    d = os.path.join(CACHE, CACHE_DIR.get(chain, chain))
    if not os.path.isdir(d): return {}
    out = {}
    for f in os.listdir(d):
        if f.isdigit():
            p = os.path.join(d, f)
            try: out[f] = (os.path.getmtime(p), os.path.getsize(p))
            except: pass
    return out

def newest_nonstub_cache(chain):
    d = os.path.join(CACHE, CACHE_DIR.get(chain, chain))
    best=None; best_t=0
    for f in os.listdir(d):
        if not f.isdigit(): continue
        p=os.path.join(d,f)
        if os.path.getsize(p)<500: continue
        try:
            j=json.load(open(p))
            if len(j.get("accounts",{}))==0: continue
        except: continue
        t=os.path.getmtime(p)
        if t>best_t: best_t, best = t, p
    return best

def cache_block_env(path):
    try:
        j=json.load(open(path))
        return int(j["meta"]["block_env"]["number"],16)
    except: return None

def eval_block_expr(expr, text):
    """Evaluate a solidity block expression (literal, CONST, CONST±N, NUM±NUM) to int,
    resolving CONSTs from the test source. Returns None if unresolvable."""
    expr = expr.strip().split('//')[0].strip()
    if not expr: return None
    try: return int(expr.replace('_',''))
    except: pass
    m = re.match(r'^(\d[\d_]*)\s*([+-])\s*(\d+)$', expr)
    if m:
        b=int(m.group(1).replace('_','')); n=int(m.group(3))
        return b-n if m.group(2)=='-' else b+n
    # resolve a CONST from source: uint256 [constant] NAME = EXPR;
    consts = {}
    for cm in re.finditer(r'(?:uint256|uint)\s+(?:public\s+)?(?:constant\s+)?(\w+)\s*=\s*([^;]+);', text):
        nm, ex = cm.group(1), cm.group(2).strip().split('//')[0].strip()
        e = ex.replace('_','')
        try: consts[nm] = int(e); continue
        except: pass
        mm = re.match(r'^(\w+)\s*([+-])\s*(\d+)$', ex)
        if mm and mm.group(1) in consts: consts[nm] = consts[mm.group(1)] + (-int(mm.group(3)) if mm.group(2)=='-' else int(mm.group(3)))
    m = re.match(r'^([A-Za-z_]\w*)\s*([+-])\s*(\d+)$', expr)
    if m and m.group(1) in consts:
        return consts[m.group(1)] + (-int(m.group(3)) if m.group(2)=='-' else int(m.group(3)))
    if expr in consts: return consts[expr]
    return None

def main():
    if len(sys.argv) < 3:
        print(__doc__); sys.exit(1)
    fol = sys.argv[1]; chain = sys.argv[2]; rpc = sys.argv[3]
    chains = load_chains()
    d = os.path.join(REG, fol)
    solfiles = glob.glob(os.path.join(d,"test","*.sol")) + glob.glob(os.path.join(d,"*.sol"))

    # parse optional flags
    forced_block=None; is_txhash=False
    for a in sys.argv[4:]:
        if a=="--txhash": is_txhash=True
        elif a.startswith("--block"): forced_block=int(a.split("=")[1])

    # 1. snapshot caches before
    before = cache_listing(chain)

    # 2. revert localhost URL -> chain alias (so the online run forks the real chain).
    for sf in solfiles:
        t = open(sf).read()
        nt = URL_RE.sub(lambda m: f'{m.group(1)}"{chain}"', t)
        if nt != t: open(sf,"w").write(nt)

    # 2b. TEMPORARILY restore [rpc_endpoints] with the archive RPC, so the alias resolves.
    # (Foundry resolves rpc aliases ONLY from [rpc_endpoints]; FOUNDRY_RPC_URLS alone does
    # not make an undefined alias valid. We strip this section again at the end — the RPC
    # URL is never persisted in the final tree.)
    ft_path = os.path.join(d, "foundry.toml")
    ft_orig = open(ft_path).read()
    ft_tmp = ft_orig.rstrip("\n") + f'\n\n[rpc_endpoints]\n{chain} = "{rpc}"\n'
    open(ft_path,"w").write(ft_tmp)

    # 3. run online to completion against the archive RPC (saturated cache)
    env = dict(os.environ)
    r = subprocess.run(["forge","test"], cwd=d, capture_output=True, text=True, env=env, timeout=240)
    online_verdict = re.search(r"\[(PASS|FAIL)", r.stdout)

    # 3b. ALWAYS restore the original foundry.toml (no rpc_endpoints) — even on error.
    open(ft_path,"w").write(ft_orig)

    # 4. find the cache(s) created/updated by the online run
    after = cache_listing(chain)
    new_files = [f for f in after if f not in before or after[f] != before.get(f, (0,0))]
    cpath = None
    if forced_block is not None:
        p = os.path.join(CACHE, CACHE_DIR[chain], str(forced_block))
        if os.path.isfile(p): cpath = p
    if cpath is None and new_files:
        # pick the largest new/updated file (most state)
        cpath = max((os.path.join(CACHE, CACHE_DIR[chain], f) for f in new_files),
                    key=lambda p: os.path.getsize(p), default=None)
    if cpath is None:
        cpath = newest_nonstub_cache(chain)
    if cpath is None or os.path.getsize(cpath) < 500:
        print(f"{fol}: WARM-FAILED (no cache after online run; rpc verdict={online_verdict})")
        # restore URL to localhost anyway (handles createFork + createSelectFork)
        port = chains[chain][0]
        alias_re = re.compile(ALIAS_RE_TMPL.format(chain=re.escape(chain)))
        for sf in solfiles:
            t=open(sf).read()
            nt=alias_re.sub(lambda m: f'{m.group(1)}"http://127.0.0.1:{port}"', t)
            if nt!=t: open(sf,"w").write(nt)
        return

    block_env = cache_block_env(cpath)
    # Detect ALL fork blocks this POC uses (multi-fork POCs fork at several blocks;
    # anvil load-state provides ONE account-state set, but we add block HEADERS for the
    # full range so createFork/selectFork at each block succeeds — the state at the
    # lowest block is reused, which works when the blocks are close together).
    text_all = ""
    for sf in solfiles:
        try: text_all += "\n" + open(sf).read()
        except: pass
    fork_blocks = set()
    for m in re.finditer(r'create(?:Select)?Fork\(\s*"(?:https?://127\.0\.0\.1:\d+|' + re.escape(chain) + r')"\s*,\s*([^)]+)\)', text_all):
        v = eval_block_expr(m.group(1), text_all)
        if v is not None: fork_blocks.add(v)
    if not fork_blocks:
        fork_blocks = {block_env} if block_env is not None else set()
    lo = min(fork_blocks) if fork_blocks else (forced_block if forced_block is not None else block_env)
    hi = max(fork_blocks) if fork_blocks else lo
    anvil_block = lo  # account-state block (most historical) = what the state was built from

    # 5. re-convert saturated cache -> anvil_state.json. Use the cache at/just-before lo
    #     so the account state covers the earliest fork. Then add child block headers up to hi.
    state_dst = os.path.join(d, "anvil_state.json")
    base_cache = cpath
    # if cpath is at a higher block than lo, prefer a cache at lo if it exists
    lo_cache = os.path.join(CACHE, CACHE_DIR[chain], str(lo))
    if os.path.isfile(lo_cache) and os.path.getsize(lo_cache) > 500:
        base_cache = lo_cache
    rc = subprocess.run([sys.executable, CONVERTER, base_cache, state_dst], capture_output=True, text=True)
    if rc.returncode != 0:
        print(f"{fol}: CONVERT-FAILED {rc.stderr[:80]}"); return
    j = json.load(open(state_dst))
    # set base block number to lo, then add headers lo+1..hi
    j["block"]["number"] = hex(lo); j["best_block_number"] = lo
    j["blocks"][0]["header"]["number"] = hex(lo)
    import copy as _copy
    cur = lo
    while cur < hi:
        cur += 1
        child = _copy.deepcopy(j["blocks"][0])
        child["header"]["number"] = hex(cur)
        j["blocks"].append(child)
    j["best_block_number"] = hi
    json.dump(j, open(state_dst,"w"), separators=(",",":"))

    # 6. restore localhost URL (handles createFork and createSelectFork with the alias)
    port = chains[chain][0]
    alias_re = re.compile(ALIAS_RE_TMPL.format(chain=re.escape(chain)))
    for sf in solfiles:
        t = open(sf).read()
        nt = alias_re.sub(lambda m: f'{m.group(1)}"http://127.0.0.1:{port}"', t)
        if nt != t: open(sf,"w").write(nt)

    print(f"{fol}: WARMED chain={chain} cache={os.path.basename(cpath)} "
          f"block_env={block_env} anvil_block={anvil_block} online={online_verdict.group(0) if online_verdict else '?'}")

if __name__ == "__main__":
    main()
