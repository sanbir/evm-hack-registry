// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Nexus DepositETH — withdrawal uses a stale share price (Pashov H-04, finding 44984)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: _depositETH and messageReceivedL2 price shares with the stored sharePrice and
    never refresh it after Lido yield arrives. A 100-share withdrawal pays 100 instead of the
    150 the backing is now worth, and the 50 of yield stays in the contract with no shares left
    against it. Both blamed formulas are preserved verbatim below (@> VULN). */

contract Asset {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract DepositETH {
    uint256 public constant BASE_POINT = 1e18;
    uint256 public sharePrice;
    uint256 public ethDeposited;
    uint256 public nETHMinted;
    mapping(address => uint256) public shares;
    Asset public asset;

    constructor(Asset _asset) {
        asset = _asset;
        sharePrice = BASE_POINT;
    }

    function pokeYield(uint256 yieldAmount) external {
        // Yield arrives from the staking position. sharePrice is intentionally not refreshed.
        asset.transferFrom(msg.sender, address(this), yieldAmount);
    }

    /// @dev The missing update. Not called from run().
    function updateSharePrice() external {
        uint256 assets = asset.balanceOf(address(this));
        if (nETHMinted == 0 || assets == 0) return;
        sharePrice = nETHMinted * BASE_POINT / assets;
    }

    function _depositETH(address receiver, uint256 _value) internal {
        uint256 nETHShares = (sharePrice * _value) / BASE_POINT; // @> VULN: deposit mints shares from the stale sharePrice
        ethDeposited += _value;
        nETHMinted += nETHShares;
        shares[receiver] += nETHShares;
        asset.transferFrom(msg.sender, address(this), _value);
    }

    function deposit(address receiver, uint256 value) external {
        _depositETH(receiver, value);
    }

    function messageReceivedL2(uint256 _id, address _receiver, uint256 _value) external {
        if (_id == 3) {
            uint256 _valueUSDCWithdraw = _value * BASE_POINT / sharePrice; // @> VULN: withdrawal pays the stale share price
            _withdrawFunds(_receiver, _value, _valueUSDCWithdraw);
        } else {
            revert("IncorrectTypeID");
        }
    }

    function _withdrawFunds(address receiver, uint256 shareAmt, uint256 assets) internal {
        shares[receiver] -= shareAmt;
        nETHMinted -= shareAmt;
        asset.transfer(receiver, assets);
    }
}

contract Exploit {
    Asset public asset; // CREATE nonce 1
    DepositETH public vault; // CREATE nonce 2
    uint256 public paid;
    uint256 public stuck;

    constructor() {
        asset = new Asset();
        vault = new DepositETH(asset);
        asset.mint(address(this), 150 ether);
        asset.approve(address(vault), type(uint256).max);
    }

    function run() external {
        vault.deposit(address(this), 100 ether);
        vault.pokeYield(50 ether);
        uint256 beforeBal = asset.balanceOf(address(this));
        vault.messageReceivedL2(3, address(this), vault.shares(address(this)));
        paid = asset.balanceOf(address(this)) - beforeBal;
        stuck = asset.balanceOf(address(vault));
        require(vault.sharePrice() == 1e18, "price never refreshed");
        require(paid == 100 ether, "paid the stale 1:1 amount");
        require(stuck == 50 ether, "50 of yield stuck");
        require(vault.shares(address(this)) == 0, "no shares left to claim the yield");
    }
}
