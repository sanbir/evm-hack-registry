// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Across Arbitrum_CustomGasToken_Adapter — OpenZeppelin, commit f56146a0 (2024-08-28).
    getL1CallValue returns L2_MAX_SUBMISSION_COST + L2_GAS_PRICE * l2GasLimit.
    Both fee terms are 18-decimal. _pullCustomGas withdraws that amount from
    the funder in the custom gas token's own decimals.

    L2_GAS_PRICE is 5 gwei. relayMessage uses a 2_000_000 gas limit.
    Submission cost is 0.01e18. The sum is 0.02e18 = 2e16 raw units.
    A 6-decimal gas token (the USDC case in the report) owes that fee
    divided by 10^(18-6) = 1e12, which is 20_000 raw units, 0.02 tokens.
    The adapter withdraws 2e16 raw units, 1e12 times the owed fee.
    The inbox then pulls that amount. The control divides before the withdraw
    and moves 20_000 units.
*/

contract Exploit {
    uint256 public constant L2_MAX_SUBMISSION_COST = 0.01 ether;
    uint256 public constant L2_GAS_PRICE = 5e9;
    uint32 public constant RELAY_MESSAGE_L2_GAS_LIMIT = 2_000_000;
    uint256 public constant SCALE = 1e12;

    address public constant FUNDER = 0x5555555555555555555555555555555555555555;
    address public constant INBOX = 0x4444444444444444444444444444444444444444;

    mapping(address => uint256) public balanceOf;

    uint256 public l2GasLimit;
    uint256 public submissionCost;
    uint256 public gasTerm;
    uint256 public requiredL1CallValue;
    uint256 public fair;
    uint256 public pulled;
    uint256 public overcharge;

    constructor() {
        balanceOf[FUNDER] = 2e16;
    }

    function run() external {
        l2GasLimit = RELAY_MESSAGE_L2_GAS_LIMIT;
        submissionCost = L2_MAX_SUBMISSION_COST;
        gasTerm = L2_GAS_PRICE * l2GasLimit;
        requiredL1CallValue = submissionCost + gasTerm;
        fair = requiredL1CallValue / SCALE;
        // @> VULN: 18-decimal getL1CallValue is withdrawn in the token's own decimals
        balanceOf[FUNDER] -= requiredL1CallValue;
        balanceOf[INBOX] += requiredL1CallValue;
        pulled = requiredL1CallValue;
        overcharge = pulled - fair;
        require(gasTerm == 1e16, "gas term");
        require(submissionCost == 1e16, "submission");
        require(requiredL1CallValue == 2e16, "call value");
        require(fair == 20_000, "fair");
        require(pulled == 2e16, "pulled");
        require(pulled / fair == SCALE, "1e12");
        require(overcharge == pulled - 20_000, "over");
        require(balanceOf[FUNDER] == 0, "funder");
        require(balanceOf[INBOX] == pulled, "inbox");
    }
}

contract GasScaled {
    uint256 public constant L2_MAX_SUBMISSION_COST = 0.01 ether;
    uint256 public constant L2_GAS_PRICE = 5e9;
    uint32 public constant RELAY_MESSAGE_L2_GAS_LIMIT = 2_000_000;
    uint256 public constant SCALE = 1e12;

    address public constant FUNDER = 0x5555555555555555555555555555555555555555;
    address public constant INBOX = 0x4444444444444444444444444444444444444444;

    mapping(address => uint256) public balanceOf;
    uint256 public pulled;

    constructor() {
        balanceOf[FUNDER] = 2e16;
    }

    function run() external {
        uint256 raw = L2_MAX_SUBMISSION_COST + L2_GAS_PRICE * uint256(RELAY_MESSAGE_L2_GAS_LIMIT);
        pulled = raw / SCALE;
        balanceOf[FUNDER] -= pulled;
        balanceOf[INBOX] += pulled;
    }
}
