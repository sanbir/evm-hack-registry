// SPDX-License-Identifier: MIT
pragma solidity 0.8.14;

import "forge-std/Test.sol";
import "../src/ajna/src/PositionManager.sol";
import "../src/ajna/src/interfaces/position/IPositionManagerOwnerActions.sol";
import "../src/ajna/src/interfaces/position/IPositionManagerState.sol";
import "../src/ajna/src/ERC20PoolFactory.sol";
import "../src/ajna/src/ERC721PoolFactory.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @dev Only the pool selectors reached by memorializePositions are needed.
contract MockAjnaPool {
    uint256 internal lpBalance;
    uint256 internal lenderDepositTime;
    uint256 internal bankruptcyTime;
    bool public transferred;

    function setLender(uint256 lpBalance_, uint256 depositTime_) external {
        lpBalance = lpBalance_;
        lenderDepositTime = depositTime_;
    }

    function setBankruptcy(uint256 bankruptcyTime_) external {
        bankruptcyTime = bankruptcyTime_;
    }

    function lenderInfo(uint256, address) external view returns (uint256, uint256) {
        return (lpBalance, lenderDepositTime);
    }

    function bucketInfo(uint256) external view returns (uint256, uint256, uint256, uint256, uint256) {
        return (0, 0, bankruptcyTime, 0, 0);
    }

    function transferLP(address, address, uint256[] calldata) external {
        transferred = true;
    }
}

contract PositionManagerHarness is PositionManager {
    using EnumerableSet for EnumerableSet.UintSet;

    constructor() PositionManager(ERC20PoolFactory(address(1)), ERC721PoolFactory(address(2))) {}

    function seed(
        address pool_,
        address owner_,
        uint256 tokenId_,
        uint256 index_,
        uint256 lps_,
        uint256 depositTime_
    ) external {
        poolKey[tokenId_] = pool_;
        _mint(owner_, tokenId_);
        positions[tokenId_][index_] = Position(lps_, depositTime_);
        positionIndexes[tokenId_].add(index_);
    }

    function trackedLP(uint256 tokenId_, uint256 index_) external view returns (uint256) {
        return positions[tokenId_][index_].lps;
    }
}

contract PoC_20074 is Test {
    PositionManagerHarness internal manager;
    MockAjnaPool internal pool;
    address internal lender = address(0xBEEF);
    uint256 internal constant TOKEN_ID = 1;
    uint256 internal constant BUCKET = 42;

    function setUp() public {
        manager = new PositionManagerHarness();
        pool = new MockAjnaPool();
        pool.setLender(0, 200);
        pool.setBankruptcy(200);

        // This is a previously memorialized 100 LP position.  The bucket is
        // now bankrupt (bankruptcyTime >= the recorded deposit time).
        manager.seed(address(pool), lender, TOKEN_ID, BUCKET, 100 ether, 100);
    }

    function test_memorialize_zeroes_existing_LP_after_bankruptcy() public {
        uint256[] memory indexes = new uint256[](1);
        indexes[0] = BUCKET;

        vm.prank(lender);
        manager.memorializePositions(
            IPositionManagerOwnerActions.MemorializePositionsParams(TOKEN_ID, indexes)
        );

        // The exact vulnerable branch in PositionManager.sol clears the old
        // LP before adding the current pool balance, destroying the lender's
        // tracked rewards for the position.
        assertEq(manager.trackedLP(TOKEN_ID, BUCKET), 0);
        assertTrue(pool.transferred());
    }
}
