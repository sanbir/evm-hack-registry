// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    MockFSD,
    Conviction,
    FSDVesting,
    FSDVestingFixed
} from "./42326-h-03-beneficiary-cant-get-fairsideconviction-nft-unless-they.sol";

contract Finding42326Test is Test {
    function test_exploit_fully_vested_claim_leaves_nft() public {
        Exploit e = new Exploit();
        e.run();

        assertEq(e.nft().ownerOf(1), address(e.vesting()), "nft stays in the vesting contract");
        assertEq(e.nft().balanceOf(address(e.vesting())), 1, "one conviction nft stuck");
        assertEq(e.nft().balanceOf(address(e)), 0, "beneficiary did not receive the nft");
        assertEq(e.fsd().balanceOf(address(e)), 1000 ether, "beneficiary was paid the full 1000 FSD");
        assertEq(e.vesting().totalClaimed(), 1000 ether, "the vest is fully claimed");
        assertTrue(e.laterClaimReverted(), "a later claim reverts");
        emit log_named_uint("nft_stuck_on_vesting", e.nft().balanceOf(address(e.vesting())));
        emit log_named_uint("beneficiary_nft", e.nft().balanceOf(address(e)));
        emit log_named_uint("beneficiary_fsd", e.fsd().balanceOf(address(e)));
        emit log_named_uint("total_claimed", e.vesting().totalClaimed());
    }

    function test_control_mints_nft_to_beneficiary() public {
        MockFSD fsd = new MockFSD();
        Conviction nft = new Conviction();
        fsd.setNft(nft);
        FSDVestingFixed fixedVesting = new FSDVestingFixed(fsd, nft);
        fsd.mint(address(fixedVesting), fixedVesting.AMOUNT() - fixedVesting.PRIOR());
        fsd.mint(address(this), fixedVesting.PRIOR());

        assertEq(fixedVesting.calculateVestingClaim(), 600 ether, "control is fully vested too");
        fixedVesting.claimVestedTokens();

        assertEq(nft.ownerOf(1), address(this), "control minted the nft to the beneficiary");
        assertEq(nft.balanceOf(address(this)), 1, "beneficiary holds 1 nft");
        assertEq(nft.balanceOf(address(fixedVesting)), 0, "vesting no longer holds the nft");
        assertEq(fsd.balanceOf(address(this)), 1000 ether, "same 1000 FSD paid");
        assertEq(fixedVesting.totalClaimed(), 1000 ether, "same full claim");
        emit log_named_uint("control_beneficiary_nft", nft.balanceOf(address(this)));
        emit log_named_uint("control_vesting_nft", nft.balanceOf(address(fixedVesting)));
    }
}
