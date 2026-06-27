// SPDX-License-Identifier: BSL-1.1

// @author samthebuilder.eth
pragma solidity ^0.8.26;

import "../routers/YodlTransferRouter.sol";
import "../routers/YodlCurveRouter.sol";
import "../routers/YodlUniswapRouter.sol";

contract YodlRouter is YodlTransferRouter, YodlCurveRouter, YodlUniswapRouter {
    constructor()
        AbstractYodlRouter()
        YodlTransferRouter()
        YodlCurveRouter(0x99a58482BD75cbab83b27EC03CA68fF489b5788f)
        YodlUniswapRouter(0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45)
    {
        version = "vSam";
        yodlFeeBps = 20;
        yodlFeeTreasury = 0x9C48d180e4eEE0dA2A899EE1E4c533cA5e92db77;
        wrappedNativeToken = IWETH9(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    }
}
