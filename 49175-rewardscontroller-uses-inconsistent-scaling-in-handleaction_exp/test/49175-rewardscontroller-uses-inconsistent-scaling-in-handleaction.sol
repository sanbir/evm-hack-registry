// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Cod3x — RewardsController.handleAction mixes scales (Spearbit, #49175)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: for an ERC6909 minipool user, handleAction subtracts the
    aToken balance (100e18, main-pool scale) from scaledTotalSupply
    (95.2e18, minipool scale). The subtraction underflows, so the withdraw
    reverts and 100e18 stays in the market. The control reads totalSupply
    on the same scale (105e18), the subtraction is 5e18, and the withdraw
    pays 100e18. */

interface IAERC6909 {
    function getIdForUnderlying(address underlying) external view returns (uint256, uint256);
    function scaledTotalSupply(uint256 id) external view returns (uint256);
    function totalSupply(uint256 id) external view returns (uint256);
}

interface IAToken {
    function WRAPPER_ADDRESS() external view returns (address);
}

contract ATokenErc6909 is IAERC6909 {
    uint256 public constant SCALED = 95.2 ether;
    uint256 public constant CONSISTENT = 105 ether;

    function getIdForUnderlying(address) external pure returns (uint256, uint256) {
        return (1, 0);
    }

    function scaledTotalSupply(uint256) external pure returns (uint256) {
        return SCALED;
    }

    function totalSupply(uint256) external pure returns (uint256) {
        return CONSISTENT;
    }
}

contract RewardsController {
    mapping(address => bool) public isMini;
    mapping(address => uint256) public totalDiff;
    mapping(address => mapping(address => uint256)) public lastReportedDiff;

    function markMini(address user) external {
        isMini[user] = true;
    }

    // RewardsController.sol — handleAction, minipool branch
    function handleAction(address user, uint256, uint256 userBalance) external {
        if (isMini[user] == true) {
            (uint256 assetID,) = IAERC6909(user).getIdForUnderlying(IAToken(msg.sender).WRAPPER_ADDRESS());
            // @> VULN: scaledTotalSupply is minipool-scaled; userBalance is main-pool-scaled
            uint256 totalSupplyAsset = IAERC6909(user).scaledTotalSupply(assetID);
            uint256 diff = totalSupplyAsset - userBalance;
            totalDiff[msg.sender] = totalDiff[msg.sender] - lastReportedDiff[msg.sender][user] + diff;
            lastReportedDiff[msg.sender][user] = diff;
            userBalance = totalSupplyAsset;
        }
    }
}

contract RewardsControllerFixed {
    mapping(address => bool) public isMini;
    mapping(address => uint256) public totalDiff;
    mapping(address => mapping(address => uint256)) public lastReportedDiff;
    uint256 public lastDiff;

    function markMini(address user) external {
        isMini[user] = true;
    }

    function handleAction(address user, uint256, uint256 userBalance) external {
        if (isMini[user] == true) {
            (uint256 assetID,) = IAERC6909(user).getIdForUnderlying(IAToken(msg.sender).WRAPPER_ADDRESS());
            uint256 totalSupplyAsset = IAERC6909(user).totalSupply(assetID);
            uint256 diff = totalSupplyAsset - userBalance;
            lastDiff = diff;
            totalDiff[msg.sender] = totalDiff[msg.sender] - lastReportedDiff[msg.sender][user] + diff;
            lastReportedDiff[msg.sender][user] = diff;
            userBalance = totalSupplyAsset;
        }
    }
}

contract Aweth is IAToken {
    address public token;
    RewardsController public controller;
    address public mini;
    uint256 public constant DEPOSIT = 100 ether;

    constructor(address _token) {
        token = _token;
    }

    function WRAPPER_ADDRESS() external view returns (address) {
        return address(this);
    }

    function wire(RewardsController _controller, address _mini) external {
        controller = _controller;
        mini = _mini;
    }

    function withdraw() external {
        uint256 currentTotalSupply = DEPOSIT;
        uint256 oldSenderBalance = DEPOSIT;
        controller.handleAction(mini, currentTotalSupply, oldSenderBalance);
        AwethToken(token).transfer(msg.sender, DEPOSIT);
    }
}

contract AwethFixed is IAToken {
    address public token;
    RewardsControllerFixed public controller;
    address public mini;

    constructor(address _token) {
        token = _token;
    }

    function WRAPPER_ADDRESS() external view returns (address) {
        return address(this);
    }

    function wire(RewardsControllerFixed _controller, address _mini) external {
        controller = _controller;
        mini = _mini;
    }

    function withdraw() external {
        controller.handleAction(mini, 100 ether, 100 ether);
        AwethToken(token).transfer(msg.sender, 100 ether);
    }
}

contract AwethToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Exploit {
    AwethToken public token; // nonce 1
    ATokenErc6909 public mini; // nonce 2
    RewardsController public rewards; // nonce 3
    Aweth public market; // nonce 4

    uint256 public stuck;
    bool public withdrew;

    constructor() {
        token = new AwethToken();
        mini = new ATokenErc6909();
        rewards = new RewardsController();
        market = new Aweth(address(token));
    }

    function run() external {
        rewards.markMini(address(mini));
        market.wire(rewards, address(mini));
        token.mint(address(market), 100 ether);
        require(token.balanceOf(address(market)) == 100 ether, "deposited");
        require(mini.scaledTotalSupply(1) == 95.2 ether, "scaled");
        try market.withdraw() {
            withdrew = true;
        } catch {
            withdrew = false;
        }
        stuck = token.balanceOf(address(market));
        require(withdrew == false, "withdraw reverted");
        require(token.balanceOf(address(this)) == 0, "caller got nothing");
        require(stuck == 100 ether, "100e18 stuck");
    }
}
