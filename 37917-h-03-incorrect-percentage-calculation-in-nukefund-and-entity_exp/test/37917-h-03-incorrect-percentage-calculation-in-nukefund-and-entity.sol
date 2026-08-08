// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    TraitForge — Incorrect percentage calculation in NukeFund and EntityForging
    when taxCut is changed from default value
    (Fitro, Code4rena 2024-07-traitforge, finding #37917, [H-03])

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. Both
    vulnerable lines are inlined VERBATIM:
      NukeFund.receive():       devShare = msg.value / taxCut;
      EntityForging.forgeWithListed(): devFee = forgingFee / taxCut;
    The Exploit deploys both contracts, has the (trusted) owner set taxCut=5
    intending a 5% dev cut, then drives one payment through each contract and
    proves the dev actually collects 20% (4x the intended cut) at the direct
    expense of the NukeFund pool and the forging lister (no fork, no
    cheatcodes).
//////////////////////////////////////////////////////////////////////////*/

/*//////////////////////////////////////////////////////////////
    Root cause: `taxCut` is documented/intended as a PERCENTAGE
    (owner comment says "Calculate developer's share (10%)" for the
    default taxCut = 10), but both contracts compute the dev share as
    `amount / taxCut` — a pure denominator, not `amount * taxCut / 100`.
    At the default value of 10 this happens to coincide with 10%
    (1/10 == 10%), masking the bug. The moment the owner calls
    `setTaxCut` with any other intended percentage, the math silently
    diverges: taxCut=5 (intended 5%) actually charges 1/5 = 20%; taxCut=20
    (intended 20%) actually charges 1/20 = 5%. There is no bound on
    `setTaxCut`, and nothing in the interface signals the inversion, so an
    owner who reads "taxCut" as "percentage cut" (as the inline comments
    themselves say) silently quadruples (or slashes) the dev's take,
    misallocating funds between the dev, the NukeFund pool, and NFT
    forgers with no attacker action required.
//////////////////////////////////////////////////////////////*/

/// @dev Minimal receiver used as the dev/forger payee so the recorder can
///      read a plain ETH balance delta as the profit signal.
contract Receiver {
    receive() external payable {}
}

/// @notice Reduced NukeFund. Collects ETH (from users interacting with the
///         nuke/claim flow), skims a "developer's share" off the top, and
///         keeps the remainder in the fund that eventually pays out nukers.
contract NukeFund {
    address public devAddress;
    uint256 public taxCut = 10; // default: owner intends 10% dev cut
    uint256 private fundBalance;

    constructor(address _devAddress) {
        devAddress = _devAddress;
    }

    function setTaxCut(uint256 _taxCut) external {
        taxCut = _taxCut;
    }

    function getFundBalance() external view returns (uint256) {
        return fundBalance;
    }

    // Fallback function to receive ETH and update fund balance
    receive() external payable {
        uint256 devShare = msg.value / taxCut; // @> VULN: intended "taxCut%" but computes 1/taxCut, not taxCut/100
        // FIX: uint256 devShare = (msg.value * taxCut) / 10_000; // taxCut expressed in basis points
        uint256 remainingFund = msg.value - devShare; // Calculate remaining funds to add to the fund
        fundBalance += remainingFund;
        (bool success, ) = payable(devAddress).call{value: devShare}("");
        require(success, "NukeFund: dev transfer failed");
    }
}

/// @notice Reduced EntityForging. A user lists an entity for forging; another
///         user pays `forgingFee` to forge with it. The fee is split between
///         the dev and the lister ("forger") using the SAME broken formula.
contract EntityForging {
    address public devAddress;
    uint256 public taxCut = 10; // default: owner intends 10% dev cut

    constructor(address _devAddress) {
        devAddress = _devAddress;
    }

    function setTaxCut(uint256 _taxCut) external {
        taxCut = _taxCut;
    }

    function forgeWithListed(address forgerReceiver) external payable {
        uint256 forgingFee = msg.value;
        uint256 devFee = forgingFee / taxCut; // @> VULN: same bug — 1/taxCut instead of taxCut%
        // FIX: uint256 devFee = (forgingFee * taxCut) / 10_000;
        uint256 forgerShare = forgingFee - devFee;
        (bool s1, ) = payable(devAddress).call{value: devFee}("");
        require(s1, "EntityForging: dev fee transfer failed");
        (bool s2, ) = payable(forgerReceiver).call{value: forgerShare}("");
        require(s2, "EntityForging: forger transfer failed");
    }
}

contract Exploit {
    NukeFund public nukeFund; // CREATE nonce 3
    EntityForging public entityForging; // CREATE nonce 4
    Receiver public devAddr; // CREATE nonce 1
    Receiver public forger; // CREATE nonce 2

    constructor() {
        devAddr = new Receiver(); // nonce 1
        forger = new Receiver(); // nonce 2
        nukeFund = new NukeFund(address(devAddr)); // nonce 3
        entityForging = new EntityForging(address(devAddr)); // nonce 4
    }

    /// @notice Owner (trusted) re-tunes taxCut to 5, intending a 5% dev cut,
    ///         then normal protocol traffic (a NukeFund deposit, a forge
    ///         payment) flows through — demonstrating the dev silently
    ///         collects 20% instead of the intended 5% on BOTH contracts.
    function run() external payable {
        require(msg.value >= 2 ether, "fund run() with >=2 ether");

        // Owner intends a 5% dev cut on both contracts.
        nukeFund.setTaxCut(5);
        entityForging.setTaxCut(5);

        // ---- NukeFund path: a user's 1 ether flows into the fund ----
        uint256 devBefore1 = address(devAddr).balance;
        uint256 fundBefore = nukeFund.getFundBalance();

        (bool ok, ) = address(nukeFund).call{value: 1 ether}("");
        require(ok, "NukeFund deposit failed");

        uint256 devGainedNuke = address(devAddr).balance - devBefore1;
        uint256 fundGainedNuke = nukeFund.getFundBalance() - fundBefore;
        uint256 intendedDevShareNuke = (1 ether * 5) / 100; // intended 5% = 0.05 ether
        uint256 intendedFundShareNuke = 1 ether - intendedDevShareNuke; // intended 0.95 ether

        // ---- EntityForging path: a forge payment of 1 ether ----
        uint256 devBefore2 = address(devAddr).balance;
        uint256 forgerBefore = address(forger).balance;

        entityForging.forgeWithListed{value: 1 ether}(address(forger));

        uint256 devGainedForge = address(devAddr).balance - devBefore2;
        uint256 forgerGained = address(forger).balance - forgerBefore;
        uint256 intendedDevFeeForge = (1 ether * 5) / 100; // intended 5% = 0.05 ether
        uint256 intendedForgerShareForge = 1 ether - intendedDevFeeForge; // intended 0.95 ether

        // HARM: on BOTH contracts, taxCut=5 (owner intends 5%) actually
        // charges 1/5 = 20% — 4x the intended cut — taken directly out of
        // the NukeFund pool's / the forger's share.
        require(devGainedNuke > intendedDevShareNuke, "no harm: nuke dev share not inflated");
        require(devGainedForge > intendedDevFeeForge, "no harm: forge dev fee not inflated");
        require(fundGainedNuke < intendedFundShareNuke, "no harm: fund not shorted");
        require(forgerGained < intendedForgerShareForge, "no harm: forger not shorted");

        // Sanity: actual dev take is exactly 20% on each leg (0.2 ether each),
        // for a combined 0.4 ether instead of the intended combined 0.1 ether.
        require(devGainedNuke == 0.2 ether, "unexpected nuke dev share");
        require(devGainedForge == 0.2 ether, "unexpected forge dev fee");
    }
}
