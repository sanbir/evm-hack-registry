pragma solidity ^0.8.20;

library Constants {
    // we will use our own fee, no need for uni v4 fee
    uint24 internal constant FEE = 0;
    // default tick spacing since we don't actually use it, so we just set it to 1
    int24 internal constant TICK_SPACING = 1;
    // default sqrt price, we don't really use this one either
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
}
