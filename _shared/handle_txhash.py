#!/usr/bin/env python3
"""Handle tx-hash-fork POCs: rewrite createSelectFork(chain, TX_HASH) to a block fork,
warm the cache at that block, then convert to an anvil state.

For these POCs the test forks by exploit-tx hash. Foundry resolves the tx to its block
and forks there. Offline, anvil can't resolve a tx hash, so we:
  1. Resolve tx -> blockNumber via RPC (one eth_getTransactionByHash per tx).
  2. Rewrite the test's createSelectFork(chain, TX_CONST) -> createSelectFork(chain, <block>).
  3. Warm ~/.foundry/cache/rpc/<chain>/<block> by running forge against the archive RPC.
  4. Convert that cache to anvil_state.json (block number set to <block>).

RPC URLs are taken from env / hardcoded here for warming ONLY and are never written to disk.
"""
import os, re, glob, json, subprocess, sys

REG = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHARED = os.path.join(REG, "_shared")
CACHE = os.path.expanduser("~/.foundry/cache/rpc")
CONVERTER = os.path.join(SHARED, "cache2anvil.py")
CACHE_DIR = {"mainnet":"mainnet","bsc":"bsc","arbitrum":"arbitrum","base":"base",
             "polygon":"polygon","optimism":"optimism","avalanche":"avalanche"}

# RPC URLs must be supplied by the caller via env var RPCS (JSON: {"chain":"url",...}) —
# NEVER hardcoded here, since this repo is public.
RPC = json.loads(os.environ.get("RPCS", "{}"))

FORK_RE = re.compile(r'(create(?:Select)?Fork\(\s*"(?:https?://127\.0\.0\.1:\d+|[a-z]+)"\s*,\s*)(\w+)(\s*\))')
TXCONST_RE = re.compile(r'(?:bytes32\s+(?:internal|private|public)?\s*(?:constant\s+)?(\w+)\s*=\s*)(0x[0-9a-fA-F]{64}|hex"[0-9a-fA-F]{64}")')

def rpc(method, params, url):
    r=subprocess.run(["curl","-s","-m","15","-X","POST","-H","Content-Type: application/json",
                      "--data",json.dumps({"jsonrpc":"2.0","method":method,"params":params,"id":1}),url],
                     capture_output=True,text=True)
    try: return json.loads(r.stdout)
    except: return {}

def load_chains():
    out={}
    with open(os.path.join(SHARED,"chains.conf")) as f:
        for line in f:
            line=line.strip()
            if not line or line.startswith("#"): continue
            p=line.split(); out[p[0]]=(int(p[1]),int(p[2]))
    return out

def process(fol, chains):
    d=os.path.join(REG,fol)
    solfiles=glob.glob(os.path.join(d,"test","*.sol"))+glob.glob(os.path.join(d,"*.sol"))
    text=""
    for sf in solfiles:
        try: text+="\n"+open(sf).read()
        except: pass
    consts={}
    for m in TXCONST_RE.finditer(text):
        name=m.group(1).strip().split()[-1] if m.group(1).strip() else None
    # capture txhash consts
    for m in re.finditer(r'bytes32\s+(?:internal\s+|private\s+|public\s+)?(?:constant\s+)?(\w+)\s*=\s*(0x[0-9a-fA-F]{64}|hex"[0-9a-fA-F]{64}")', text):
        name=m.group(1); val=m.group(2)
        if val.startswith('hex"'): val="0x"+val[4:-1]
        consts[name]=val
    # find the fork call using a const
    m=FORK_RE.search(text)
    if not m: return ("no_fork", fol)
    txname=m.group(2)
    txh=consts.get(txname)
    if not txh:
        # maybe it's a direct hex literal
        if re.match(r'^0x[0-9a-fA-F]{64}$', txname) or txname.startswith('hex"'): txh=txname
        else: return ("no_tx_const", f"{fol}: {txname}")
    # detect chain from the fork url/alias
    chain_m=re.search(r'create(?:Select)?Fork\(\s*"(https?://127\.0\.0\.1:\d+|[a-z]+)"', text)
    chain_url=chain_m.group(1) if chain_m else ""
    # map url->chain via port
    chain=None
    if chain_url.startswith("http"):
        port=int(chain_url.split(":")[-1])
        for c,(p,cid) in chains.items():
            if p==port: chain=c; break
    else:
        chain=chain_url
    if chain not in RPC: return ("no_rpc", f"{fol}: chain {chain}")
    # resolve tx->block
    res=rpc("eth_getTransactionByHash",[txh],RPC[chain])
    bn=res.get("result",{}).get("blockNumber") if res.get("result") else None
    if not bn: return ("tx_resolve_fail", f"{fol}: {txh[:20]}")
    block=int(bn,16)
    # rewrite test: replace TX_CONST with block number literal
    for sf in solfiles:
        try: t=open(sf).read()
        except: continue
        nt=FORK_RE.sub(lambda mm: f"{mm.group(1)}{block}_{mm.group(3).replace(')', '')})".replace(f"{block}_)",f"{block})"), t) if False else None
        # simpler: targeted replacement of the exact const occurrence in the fork call
        nt=re.sub(rf'(create(?:Select)?Fork\(\s*"(?:https?://127\.0\.0\.1:\d+|[a-z]+)"\s*,\s*){re.escape(txname)}(\s*\))',
                  rf'\g<1>{block}\g<2>', t)
        if nt!=t: open(sf,"w").write(nt)
    # warm cache at block: run forge (fork now uses block) against rpc
    warm_env=dict(os.environ, FOUNDRY_RPC_URLS=f"{chain}={RPC[chain]}")
    r=subprocess.run(["forge","test"],cwd=d,capture_output=True,text=True,env=warm_env,timeout=180)
    cpath=os.path.join(CACHE, CACHE_DIR.get(chain,chain), str(block))
    if not os.path.isfile(cpath) or os.path.getsize(cpath)<500:
        # cache may be keyed at a nearby block; find it
        cdir=os.path.join(CACHE,CACHE_DIR.get(chain,chain))
        cand=[f for f in os.listdir(cdir) if f.isdigit() and os.path.getsize(os.path.join(cdir,f))>500]
        # pick the one whose block_env matches 'block' closest (prefer exact)
        best=None
        for f in cand:
            try:
                j=json.load(open(os.path.join(cdir,f)))
                be=int(j["meta"]["block_env"]["number"],16)
                if be==block: best=os.path.join(cdir,f); break
            except: pass
        cpath=best
    if not cpath: return ("warm_fail", f"{fol}: no cache for block {block}")
    # convert to anvil state (block override = resolved block)
    state_dst=os.path.join(d,"anvil_state.json")
    r2=subprocess.run([sys.executable,CONVERTER,cpath,state_dst],capture_output=True,text=True)
    if r2.returncode!=0: return ("convert_fail", f"{fol}: {r2.stderr[:80]}")
    # override block number
    j=json.load(open(state_dst))
    j["block"]["number"]=hex(block); j["best_block_number"]=block
    j["blocks"][0]["header"]["number"]=hex(block)
    json.dump(j,open(state_dst,"w"),separators=(",",":"))
    return ("ok", f"{fol}: {chain} block {block}")

if __name__=="__main__":
    chains=load_chains()
    pocs=sys.argv[1:]
    for fol in pocs:
        status,info=process(fol,chains)
        print(f"{fol}: {status} {('('+info+')') if info else ''}")
