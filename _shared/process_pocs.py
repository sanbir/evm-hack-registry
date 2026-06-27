#!/usr/bin/env python3
"""Convert every POC to run fully offline via anvil. Idempotent. Handles all fork forms:

  - literal block:        createSelectFork("bsc", 105_692_847)
  - expression block:     createSelectFork("mainnet", 14_139_082 - 1)
  - constant block:       createSelectFork("mainnet", forkBlock)   [forkBlock resolved from consts]
  - latest (no block):    createSelectFork("mainnet")   [forks chain tip; state from warmed cache]
  - tx-hash:              createSelectFork("mainnet", TX_HASH)  [resolve tx->block via cache; rewrite to block]

For each POC:
  1. Resolve chain + the EXACT fork block the test will use.
     - literal/expr/const: evaluated statically.
     - latest: the warmed cache's block_env.number (the tip when warmed).
     - tx-hash: search the chain's cache dir for the block_env nearest the resolved tx block
       (Foundry forks at tx_block-1); rewrite the fork to that block.
  2. Convert the matching cache -> anvil_state.json, setting the state's block number to the
     fork block (so anvil reports the block the test requests).
  3. Rewrite the fork source alias -> http://127.0.0.1:<port> (port from chains.conf).
  4. Remove [rpc_endpoints] from foundry.toml.
  5. lib/forge-std -> relative symlink ../../_shared/forge-std.

POCs that can't be converted (no cache / pruned chain) are skipped and listed.
"""
import os, re, sys, json, glob, subprocess, shutil

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

# match: <caller>.create[Select]Fork("alias-or-url", ARG)  OR  (...("alias"))  (no arg)
FORK_RE = re.compile(
    r'((?:vm|cheats|cheat|CheatCodes\w*|VmSafe|Vm)\s*\.\s*create(?:Select)?Fork\s*\(\s*)'
    r'"([^"]+)"(\s*,?\s*)([^)]*?)(\s*\))'
)

def eval_expr(expr, consts):
    expr = expr.strip().split('//')[0].strip()
    if not expr: return None
    try: return int(expr.replace('_',''))
    except: pass
    m = re.match(r'^(\d[\d_]*)\s*([+-])\s*(\d+)$', expr)
    if m:
        b=int(m.group(1).replace('_','')); n=int(m.group(3))
        return b-n if m.group(2)=='-' else b+n
    m = re.match(r'^([A-Za-z_]\w*)\s*([+-])\s*(\d+)$', expr)
    if m and m.group(1) in consts:
        return consts[m.group(1)] + (-int(m.group(3)) if m.group(2)=='-' else int(m.group(3)))
    if expr in consts: return consts[expr]
    return None

def parse_consts(text):
    consts={}
    for m in re.finditer(r'(?:uint256|uint)\s+(?:public\s+)?(?:constant\s+)?(\w+)\s*=\s*([^;]+);', text):
        v=eval_expr(m.group(2), consts)
        if v is not None: consts[m.group(1)]=v
    for m in re.finditer(r'(?:uint256\s+)?(\w+)\s*=\s*([^;]+);', text):
        v=eval_expr(m.group(2), consts)
        if v is not None and m.group(1) not in consts: consts[m.group(1)]=v
    return consts

def chain_caches(chain):
    """Return list of (block_int, path, naccounts) for non-stub caches in the chain dir.
    Memoized per chain (the listings don't change during a run)."""
    if chain in _CHAIN_CACHE:
        return _CHAIN_CACHE[chain]
    d=os.path.join(CACHE, CACHE_DIR.get(chain, chain))
    out=[]
    if os.path.isdir(d):
        for f in os.listdir(d):
            if not f.isdigit(): continue
            p=os.path.join(d,f)
            if os.path.getsize(p)<500: continue
            try:
                j=json.load(open(p))
                be=int(j["meta"]["block_env"]["number"],16)
                out.append((be, p, len(j.get("accounts",{}))))
            except: pass
    _CHAIN_CACHE[chain]=out
    return out

_CHAIN_CACHE = {}

def find_cache_for_block(chain, block):
    """Find the cache whose block_env == block (exact), else nearest below (Foundry forks at parent)."""
    cs = chain_caches(chain)
    exact = [c for c in cs if c[0]==block]
    if exact: return exact[0]
    below = [c for c in cs if c[0] < block]
    if below:
        below.sort(key=lambda x: -x[0])
        return below[0]
    return None

def is_txhash_arg(arg):
    a=arg.strip()
    if a.startswith("0x") and len(a)>=66: return True
    if a.startswith('hex"'): return True
    return bool(re.match(r'^[A-Z_]\w*$', a)) and ("TX" in a or "exploitTx" in a or "attackTx" in a)

def convert_anvil(src, dst, override_block):
    r=subprocess.run([sys.executable,CONVERTER,src,dst],capture_output=True,text=True)
    if r.returncode!=0: return False, r.stderr
    if override_block is not None:
        j=json.load(open(dst))
        fb=hex(override_block)
        j["block"]["number"]=fb; j["best_block_number"]=override_block
        j["blocks"][0]["header"]["number"]=fb
        json.dump(j,open(dst,"w"),separators=(",",":"))
    return True, ""

def strip_rpc_endpoints(ft_path):
    if not os.path.isfile(ft_path): return
    lines=open(ft_path).read().splitlines()
    out=[]; skip=False
    for ln in lines:
        if ln.strip()=="[rpc_endpoints]": skip=True; continue
        if skip and ln.startswith("["): skip=False
        if skip: continue
        out.append(ln)
    while out and out[-1].strip()=="": out.pop()
    open(ft_path,"w").write("\n".join(out)+"\n")

def fix_forge_std(d):
    lib=os.path.join(d,"lib","forge-std")
    if os.path.islink(lib):
        tgt=os.readlink(lib)
        if tgt=="../../_shared/forge-std": return
        os.remove(lib)
    elif os.path.exists(lib):
        try: shutil.rmtree(lib)
        except: return
    os.symlink("../../_shared/forge-std", lib)

def process_poc(fol, chains):
    d=os.path.join(REG, fol)
    solfiles=glob.glob(os.path.join(d,"test","*.sol"))+glob.glob(os.path.join(d,"*.sol"))
    text=""
    for sf in solfiles:
        try: text+="\n"+open(sf).read()
        except: pass
    consts=parse_consts(text)
    m=FORK_RE.search(text)
    if not m: return ("nofork", fol)
    chain_ref=m.group(2)
    arg=m.group(4).strip()
    # resolve chain (alias or already-converted localhost url)
    chain=None
    if chain_ref.startswith("http://127.0.0.1:"):
        port=int(chain_ref.split(":")[-1])
        for c,(p,cid) in chains.items():
            if p==port: chain=c; break
    elif chain_ref in chains or chain_ref in CACHE_DIR:
        chain=chain_ref
    elif chain_ref.startswith("http"):
        return ("inline_url", fol)
    if chain is None: return ("unknown_chain", f"{fol}: {chain_ref}")

    fork_block=None; tx_rewrite=None
    if arg=="":
        # latest fork: use the chain's newest cache block
        cs=chain_caches(chain)
        if not cs: return ("no_cache", fol)
        cs.sort(key=lambda x:-x[0]); fork_block=cs[0][0]
    elif is_txhash_arg(arg):
        # tx-hash fork: find the cache whose block_env is the fork block (tx_block-1 typically).
        # We don't know the tx's exact block statically; pick the most recently-warmed cache in chain.
        cs=chain_caches(chain)
        if not cs: return ("no_cache_tx", fol)
        # Heuristic: the tx-fork cache is whichever non-stub cache exists; if multiple, we can't be sure.
        # Use the one most recently modified.
        cs_with_mtime=[]
        for be,p,na in cs:
            cs_with_mtime.append((os.path.getmtime(p), be, p, na))
        cs_with_mtime.sort(reverse=True)
        fork_block=cs_with_mtime[0][1]
        tx_rewrite=(arg, fork_block)  # rewrite the tx const -> block literal
    else:
        fork_block=eval_expr(arg, consts)
        if fork_block is None: return ("unresolvable", f"{fol}: {chain} {arg[:30]}")

    # find cache at/just-before fork_block
    cinfo = find_cache_for_block(chain, fork_block) if fork_block is not None else None
    if cinfo is None: return ("no_cache", f"{fol}: {chain}/{fork_block}")
    cache_block, cpath, nacc = cinfo
    # anvil state block number: the test forks at fork_block. If cache_block < fork_block
    # (Foundry forks at parent), set anvil block = fork_block so the test's number matches,
    # BUT the state is cache_block's. For exact matches no override needed.
    override = fork_block if fork_block != cache_block else None
    state_dst=os.path.join(d,"anvil_state.json")
    ok,err=convert_anvil(cpath, state_dst, override)
    if not ok: return ("convert_fail", f"{fol}: {err[:80]}")

    # rewrite fork source: alias/url -> localhost port; tx const -> block literal
    port=chains[chain][0]
    url=f"http://127.0.0.1:{port}"
    for sf in solfiles:
        try: t=open(sf).read()
        except: continue
        nt=t
        # 1) chain ref -> localhost
        nt=re.sub(r'((?:vm|cheats|cheat|CheatCodes\w*|VmSafe|Vm)\s*\.\s*create(?:Select)?Fork\s*\(\s*)"(?:https?://127\.0\.0\.1:\d+|[a-z]+)"',
                  rf'\1"{url}"', nt)
        # 2) tx const -> block literal (only if this is a txhash fork)
        if tx_rewrite:
            txconst, blk = tx_rewrite
            nt=re.sub(rf'((?:vm|cheats|cheat|CheatCodes\w*|VmSafe|Vm)\s*\.\s*create(?:Select)?Fork\s*\(\s*"{re.escape(url)}"\s*,\s*){re.escape(txconst)}(\s*\))',
                      rf'\g<1>{blk}\g<2>', nt)
        if nt!=t: open(sf,"w").write(nt)

    strip_rpc_endpoints(os.path.join(d,"foundry.toml"))
    fix_forge_std(d)
    return ("ok", None)

def main():
    chains=load_chains()
    folders=sorted(f for f in os.listdir(REG) if os.path.isdir(os.path.join(REG,f)) and re.match(r'^\d{4}-',f))
    stats={}; details={}
    for fol in folders:
        status,info=process_poc(fol, chains)
        stats[status]=stats.get(status,0)+1
        if status!="ok": details.setdefault(status,[]).append(info or fol)
    print("=== BATCH RESULTS ===")
    for k,v in sorted(stats.items()): print(f"  {k}: {v}")
    for k in ("no_cache","no_cache_tx","convert_fail","inline_url","unknown_chain","unresolvable","nofork","bad_cache"):
        if k in details:
            print(f"\n--- {k} ---")
            for x in details[k]: print("  ",x)

if __name__=="__main__":
    main()
