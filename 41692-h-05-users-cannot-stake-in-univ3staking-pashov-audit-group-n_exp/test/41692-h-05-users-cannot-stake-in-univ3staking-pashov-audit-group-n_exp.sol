// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    Note,
    PositionManager,
    UniswapV3StakingFixed
} from "./41692-h-05-users-cannot-stake-in-univ3staking-pashov-audit-group-n.sol";

contract Finding41692Test is Test {
    function test_exploit_stake_reverts_lp_stays_with_user() public {
        Exploit e = new Exploit();
        e.run();

        (uint256 recorded,,, bool isStaked) = e.staking().stakes(1);
        assertEq(e.pm().ownerOf(7), address(e), "NFT still with the user");
        assertEq(recorded, 0, "no liquidity recorded");
        assertFalse(isStaked, "not staked");
        assertEq(e.lp().balanceOf(address(e)), 1_000_000, "1_000_000 LP stuck with the user");
        assertEq(e.pm().LIQUIDITY(), 1_000_000, "position liquidity");
        emit log_named_uint("stuck_lp", e.lp().balanceOf(address(e)));
        emit log_named_uint("recorded_liquidity", recorded);
        emit log_named_address("nft_holder", e.pm().ownerOf(7));
    }

    function test_control_stake_records_the_position() public {
        Note note = new Note();
        PositionManager pm = new PositionManager();
        UniswapV3StakingFixed fixedStaking = new UniswapV3StakingFixed(note, pm);
        note.mint(address(this), 1);
        pm.mint(address(this), 7);
        pm.approve(address(fixedStaking), 7);

        fixedStaking.stake(1, 7);

        (uint256 recorded,, uint256 tokenId, bool isStaked) = fixedStaking.stakes(1);
        assertEq(pm.ownerOf(7), address(fixedStaking), "NFT custodied");
        assertEq(recorded, 1_000_000, "liquidity recorded");
        assertEq(tokenId, 7, "token id");
        assertTrue(isStaked, "staked");
    }
}
