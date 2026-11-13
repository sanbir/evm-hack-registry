// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Cork H-2 (Sherlock 2024-08, issue 68).
    emptyReservePartial returns the reserve left after the transfer, which is
    0 when the reserve is fully emptied. The last LV redeem then tries to sell
    every CT token and reverts, locking the depositor's RA in the vault.
*/

contract Erc20 {
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s) {
        symbol = s;
    }

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
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function burn(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
    }
}

contract FlashSwapRouter {
    struct DsReserve {
        Erc20 ds;
        uint256 reserve;
    }

    DsReserve public dsPos;
    uint256 public lastReturned;

    constructor(Erc20 ds) {
        dsPos.ds = ds;
        dsPos.reserve = 10 ether;
    }

    function getLvReserve() external view returns (uint256) {
        return dsPos.reserve;
    }

    function emptyReservePartial(uint256 amount, address to) external returns (uint256 reserve) {
        dsPos.ds.transfer(to, amount);
        dsPos.reserve -= amount;
        // @> VULN: returns the leftover reserve, which is 0 after a full empty
        reserve = dsPos.reserve;
        lastReturned = reserve;
    }

    function emptyReservePartialFixed(uint256 amount, address to) external returns (uint256 reserve) {
        dsPos.ds.transfer(to, amount);
        dsPos.reserve -= amount;
        reserve = amount;
        lastReturned = reserve;
    }
}

contract Vault {
    Erc20 public ra;
    Erc20 public ct;
    Erc20 public ds;
    FlashSwapRouter public router;
    uint256 public shares;

    constructor(Erc20 _ra, Erc20 _ct, Erc20 _ds, FlashSwapRouter _router) {
        ra = _ra;
        ct = _ct;
        ds = _ds;
        router = _router;
    }

    function deposit(uint256 amount) external {
        ra.transferFrom(msg.sender, address(this), amount);
        shares += amount;
    }

    function _redeem(bool fixedPath) internal {
        uint256 ammCtBalance = ct.balanceOf(address(this));
        uint256 reservedDs = router.getLvReserve();
        uint256 redeemAmount = reservedDs >= ammCtBalance ? ammCtBalance : reservedDs;
        if (fixedPath) {
            reservedDs = router.emptyReservePartialFixed(redeemAmount, address(this));
        } else {
            reservedDs = router.emptyReservePartial(redeemAmount, address(this));
        }
        ct.burn(redeemAmount);
        ds.burn(redeemAmount);
        uint256 ctSellAmount = reservedDs >= ammCtBalance ? 0 : ammCtBalance - reservedDs;
        if (ctSellAmount != 0) {
            ct.transfer(address(router), ctSellAmount);
        }
        uint256 payout = ra.balanceOf(address(this));
        ra.transfer(msg.sender, payout);
        shares = 0;
    }

    function redeemEarly() external {
        _redeem(false);
    }

    function redeemEarlyFixed() external {
        _redeem(true);
    }
}

contract Exploit {
    Erc20 public ra;
    Erc20 public ct;
    Erc20 public ds;
    FlashSwapRouter public router;
    Vault public vault;
    bool public redeemReverted;
    uint256 public constant AMOUNT = 10 ether;

    constructor() {
        ra = new Erc20("RA");
        ct = new Erc20("CT");
        ds = new Erc20("DS");
        router = new FlashSwapRouter(ds);
        vault = new Vault(ra, ct, ds, router);
        ds.mint(address(router), AMOUNT);
        ct.mint(address(vault), AMOUNT);
        ra.mint(address(this), AMOUNT);
    }

    function run() external {
        ra.approve(address(vault), AMOUNT);
        vault.deposit(AMOUNT);
        try vault.redeemEarly() {
            redeemReverted = false;
        } catch {
            redeemReverted = true;
        }
        require(redeemReverted, "revert");
        require(ra.balanceOf(address(vault)) == AMOUNT, "locked");
        require(ra.balanceOf(address(this)) == 0, "user");
        require(router.getLvReserve() == AMOUNT, "reserve");
    }

    function runFixed() external {
        ra.approve(address(vault), AMOUNT);
        vault.deposit(AMOUNT);
        vault.redeemEarlyFixed();
        require(ra.balanceOf(address(this)) == AMOUNT, "returned");
        require(ra.balanceOf(address(vault)) == 0, "empty");
    }
}
