// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Blueberry WAuraPools — AURA cliff math uses the post-claim supply
    (Sherlock 2023-07 H-4, finding #24319).
    SYNTHETIC, cheatcode-free. _getAuraPendingReward is the audited formula
    from WAuraPools.sol L209-L249. withdraw claims every participant's BAL,
    the minter mints AURA at the pre-claim cliff, and the wrapper then prices
    each user with the new cliff. Two LPs owed 1950 AURA each are paid 975. */

contract Aura {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    function INIT_MINT_AMOUNT() external pure returns (uint256) {
        return 0;
    }

    function reductionPerCliff() external pure returns (uint256) {
        return 10;
    }

    function totalCliffs() external pure returns (uint256) {
        return 500;
    }

    function EMISSIONS_MAX_SUPPLY() external pure returns (uint256) {
        return type(uint256).max;
    }

    function mint(address to, uint256 amt) external {
        totalSupply += amt;
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "aura");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract AuraPools {
    function getRewardMultipliers(address) external pure returns (uint256) {
        return 1e18;
    }
}

contract WAuraPools {
    uint256 internal constant REWARD_MULTIPLIER_DENOMINATOR = 1e18;
    Aura public AURA;
    AuraPools public auraPools;
    address public userA;
    address public userB;
    uint256 public balA;
    uint256 public balB;
    bool public claimed;
    uint256 public totalMinted;
    uint256 public paidA;
    uint256 public paidB;

    constructor(Aura aura_, AuraPools pools_) {
        AURA = aura_;
        auraPools = pools_;
    }

    function setUsers(address a, address b, uint256 aBal, uint256 bBal) external {
        userA = a;
        userB = b;
        balA = aBal;
        balB = bBal;
    }

    /// Minter quote at the supply observed BEFORE this claim. Not the wrapper's view.
    function _minterQuote(uint256 balAmount) internal view returns (uint256 mintAmount) {
        uint256 totalCliffs = AURA.totalCliffs();
        uint256 emissionsMinted = AURA.totalSupply();
        uint256 cliff = emissionsMinted / AURA.reductionPerCliff();
        if (cliff < totalCliffs) {
            uint256 reduction = ((totalCliffs - cliff) * 5) / 2 + 700;
            mintAmount = (balAmount * reduction) / totalCliffs;
        }
    }

    /// Verbatim cliff formula from WAuraPools._getAuraPendingReward (L209-L249).
    function _getAuraPendingReward(uint256 balAmount) public view returns (uint256 mintAmount) {
        uint256 mintRequestAmount =
            (balAmount * auraPools.getRewardMultipliers(address(this))) / REWARD_MULTIPLIER_DENOMINATOR;
        uint256 totalSupply = AURA.totalSupply();
        uint256 initAmount = AURA.INIT_MINT_AMOUNT();
        uint256 minterMinted;
        uint256 reductionPerCliff = AURA.reductionPerCliff();
        uint256 totalCliffs = AURA.totalCliffs();
        uint256 emissionMaxSupply = AURA.EMISSIONS_MAX_SUPPLY();
        uint256 emissionsMinted = totalSupply - initAmount - minterMinted;
        // @> VULN: cliff is taken from totalSupply after this claim already minted the AURA
        uint256 cliff = emissionsMinted / reductionPerCliff;
        if (cliff < totalCliffs) {
            uint256 reduction = ((totalCliffs - cliff) * 5) / 2 + 700;
            mintAmount = (mintRequestAmount * reduction) / totalCliffs;
            uint256 amtTillMax = emissionMaxSupply - emissionsMinted;
            if (mintAmount > amtTillMax) {
                mintAmount = amtTillMax;
            }
        }
    }

    function withdraw(address user) external virtual returns (uint256 paid) {
        uint256 userBal = user == userA ? balA : balB;
        require(userBal > 0, "user");
        if (!claimed) {
            uint256 quote = _minterQuote(balA + balB);
            AURA.mint(address(this), quote);
            totalMinted = quote;
            claimed = true;
        }
        paid = _getAuraPendingReward(userBal);
        require(AURA.transfer(user, paid), "pay");
        if (user == userA) paidA = paid;
        else paidB = paid;
    }
}

contract Exploit {
    Aura public aura;
    AuraPools public pools;
    WAuraPools public wrapper;
    address public userA;
    address public userB;

    constructor() {
        aura = new Aura();
        pools = new AuraPools();
        wrapper = new WAuraPools(aura, pools);
        userA = address(0xA11CE);
        userB = address(0xB0B);
    }

    function run() external {
        wrapper.setUsers(userA, userB, 500, 500);
        wrapper.withdraw(userA);
        wrapper.withdraw(userB);
        require(wrapper.totalMinted() == 3900, "minted at cliff 0");
        require(wrapper.paidA() == 975, "A paid at cliff 390");
        require(wrapper.paidB() == 975, "B paid at cliff 390");
        require(aura.balanceOf(address(wrapper)) == 1950, "stuck");
        require(aura.balanceOf(userA) == 975, "A balance");
        require(aura.balanceOf(userB) == 975, "B balance");
    }
}
