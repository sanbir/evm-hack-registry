// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  UMA LongShortPair — the creator pulls a proposer reward into the pair
    and expire() never forwards that balance (OpenZeppelin C01, finding 10705).
    SYNTHETIC, one chain, cheatcode-free. createLongShortPair transfers
    100 collateral into the pair. expire() pulls a second 100 from the caller
    and approves only that 100 to the oracle, which the proposer can claim.
    The prepaid 100 stays in the pair with no withdrawal. The control does
    not take the prepaid reward, so the single 100 is paid to the proposer. */

library SafeERC20_10705 {
    function safeTransferFrom(Collateral token, address from, address to, uint256 amount) internal {
        token.transferFrom(from, to, amount);
    }

    function safeApprove(Collateral token, address spender, uint256 amount) internal {
        token.approve(spender, amount);
    }
}

contract Collateral {
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
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract OptimisticOracle {
    Collateral public collateral;
    uint256 public storedReward;

    constructor(Collateral _collateral) {
        collateral = _collateral;
    }

    function requestPrice(uint256 proposerReward) external {
        collateral.transferFrom(msg.sender, address(this), proposerReward);
        storedReward = proposerReward;
    }

    function claim(address proposer) external returns (uint256 paid) {
        paid = storedReward;
        storedReward = 0;
        if (paid > 0) collateral.transfer(proposer, paid);
    }
}

contract LongShortPair {
    using SafeERC20_10705 for Collateral;

    Collateral public collateralToken;
    OptimisticOracle public optimisticOracle;
    uint256 public proposerReward;

    constructor(Collateral _collateral, OptimisticOracle _oracle, uint256 _reward) {
        collateralToken = _collateral;
        optimisticOracle = _oracle;
        proposerReward = _reward;
    }

    function expire() external {
        if (proposerReward > 0) {
            collateralToken.safeTransferFrom(msg.sender, address(this), proposerReward);
            collateralToken.safeApprove(address(optimisticOracle), proposerReward);
        }
        optimisticOracle.requestPrice(proposerReward);
    }
}

contract LongShortPairCreator {
    using SafeERC20_10705 for Collateral;

    Collateral public collateral;
    OptimisticOracle public oracle;
    uint256 public proposerReward;

    constructor(Collateral _collateral, OptimisticOracle _oracle, uint256 _reward) {
        collateral = _collateral;
        oracle = _oracle;
        proposerReward = _reward;
    }

    function createLongShortPair() external returns (LongShortPair lsp) {
        lsp = new LongShortPair(collateral, oracle, proposerReward);
        if (proposerReward > 0) {
            // @> VULN: prepaid proposer reward is pulled into the pair and never forwarded to the oracle
            collateral.safeTransferFrom(msg.sender, address(lsp), proposerReward);
        }
    }
}

contract Exploit {
    uint256 public constant REWARD = 100 ether;

    Collateral public collateral;
    OptimisticOracle public oracle;
    LongShortPairCreator public creator;
    LongShortPair public pair;
    uint256 public claimed;

    constructor() {
        collateral = new Collateral();
        oracle = new OptimisticOracle(collateral);
        creator = new LongShortPairCreator(collateral, oracle, REWARD);
        collateral.mint(address(this), 2 * REWARD);
    }

    function run() external {
        collateral.approve(address(creator), REWARD);
        pair = creator.createLongShortPair();
        collateral.approve(address(pair), REWARD);
        pair.expire();
        claimed = oracle.claim(address(this));
        require(claimed == REWARD, "expire path paid");
        require(collateral.balanceOf(address(pair)) == REWARD, "prepaid stuck");
        require(oracle.claim(address(this)) == 0, "no second claim");
    }
}
